defmodule AgentManager.MCP do
  @moduledoc """
  Model Context Protocol client: connects to MCP servers and exposes their
  tools to bots.

  Each server is one `AgentManager.MCP.Client` process under
  `AgentManager.MCP.Supervisor`. Servers come from config (or `MCP_SERVERS`,
  a JSON array, at runtime) and can also be started with `start_server/1`:

      config :agent_manager, AgentManager.MCP,
        servers: [
          # local process speaking JSON-RPC over stdin/stdout
          %{name: "filesystem", transport: :stdio, command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/docs"]},
          # remote server over Streamable HTTP
          %{name: "crm", transport: :http, url: "https://crm.example.com/mcp",
            headers: %{"authorization" => {:system, "CRM_MCP_TOKEN"}}}
        ]

  Server names must be unique and are used in tool ids (`mcp:<server>/<tool>`).
  A server that can't be reached is retried with backoff and reported as
  `:error` by `servers/0`; it never takes the rest of the system down.
  """

  require Logger

  alias AgentManager.MCP.Client

  @registry AgentManager.MCP.Registry
  @supervisor AgentManager.MCP.Supervisor

  @doc "Starts a client for `config` (see moduledoc for the shape)."
  def start_server(config) do
    config = normalize(config)
    DynamicSupervisor.start_child(@supervisor, {Client, config})
  end

  def stop_server(name) do
    case whereis(name) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Status of every server: name, status, tool count, last error."
  def servers do
    for {name, pid, info} <- entries() do
      %{
        name: name,
        pid: pid,
        status: info[:status] || :connecting,
        transport: info[:transport],
        server_info: info[:server_info],
        tools: length(info[:tools] || []),
        error: info[:error]
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc "Tools of every ready server: `%{server, name, description, input_schema}`."
  def tools do
    for {server, _pid, %{status: :ready, tools: tools}} <- entries(), tool <- tools do
      Map.put(tool, :server, server)
    end
  end

  @doc "Calls `tool` on `server`. Returns `{:ok, %{content: text, is_error: bool}}`."
  def call_tool(server, tool, arguments, timeout \\ 30_000) do
    case whereis(server) do
      nil -> {:error, {:unknown_server, server}}
      pid -> GenServer.call(pid, {:call_tool, tool, arguments, timeout}, timeout + 1_000)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  def whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp entries do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc false
  # Starts the servers listed in config; run once at boot by MCP.Root.
  def start_configured do
    for config <- Application.get_env(:agent_manager, __MODULE__, [])[:servers] || [] do
      case start_server(config) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("[mcp] could not start #{inspect(config[:name])}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc false
  def normalize(config) do
    config = Map.new(config, fn {k, v} -> {to_atom(k), v} end)

    config
    |> Map.update(:transport, :stdio, &to_atom/1)
    |> Map.update!(:name, &to_string/1)
    |> Map.update(:args, [], & &1)
    |> Map.update(:env, %{}, &resolve_map/1)
    |> Map.update(:headers, %{}, &resolve_map/1)
  end

  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_atom(v)

  defp resolve_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), resolve(v)} end)
  defp resolve({:system, var}), do: System.get_env(var) || ""
  defp resolve(v), do: to_string(v)
end

defmodule AgentManager.MCP.Client do
  @moduledoc """
  One connection to one MCP server (protocol revision 2025-06-18).

  Lifecycle: `initialize` -> `notifications/initialized` -> `tools/list`, then
  `tools/call` on demand. The tool list is refreshed when the server sends
  `notifications/tools/list_changed`.

  Transports:

    * `:stdio` - the server runs as an OS process (`Port`); newline-delimited
      JSON-RPC over stdin/stdout. Calls are asynchronous: many can be in
      flight, matched back by request id.
    * `:http` - Streamable HTTP: every message is a POST; the reply is JSON or
      an SSE stream. `Mcp-Session-Id` is kept and sent back. Each call runs in
      its own task, so a slow tool doesn't block others.

  Connection failures (bad command, server exit, HTTP errors, expired
  session) move the client to `:error` and schedule a reconnect with
  exponential backoff; pending calls get `{:error, :disconnected}`.
  """

  use GenServer, restart: :transient
  require Logger

  @protocol "2025-06-18"
  @registry AgentManager.MCP.Registry
  @connect_timeout 30_000
  @max_backoff 60_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: {:via, Registry, {@registry, config.name}})
  end

  def child_spec(config), do: %{super(config) | id: {__MODULE__, config.name}}

  # -- lifecycle ---------------------------------------------------------------

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    state = %{
      config: config,
      status: :connecting,
      port: nil,
      buffer: "",
      session: nil,
      pending: %{},
      next_id: 1,
      tools: [],
      server_info: nil,
      error: nil,
      attempts: 0
    }

    publish(state)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        Logger.info("[mcp] #{state.config.name}: ready with #{length(state.tools)} tool(s)")
        {:noreply, publish(%{state | status: :ready, error: nil, attempts: 0})}

      {:error, reason, state} ->
        {:noreply, fail(state, reason)}
    end
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  # stdio: a complete line from the server
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    {:noreply, handle_line(%{state | buffer: ""}, line)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:noreply, fail(%{state | port: nil}, {:server_exited, code})}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:noreply, fail(%{state | port: nil}, {:server_exited, reason})}

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{:call, from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:tools_refreshed, tools}, state),
    do: {:noreply, publish(%{state | tools: tools})}

  def handle_info({:http_failed, reason}, state), do: {:noreply, fail(state, reason)}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- tool calls --------------------------------------------------------------

  @impl true
  def handle_call({:call_tool, _tool, _args, _timeout}, _from, %{status: status} = state)
      when status != :ready,
      do: {:reply, {:error, {:not_connected, state.error}}, state}

  def handle_call({:call_tool, tool, args, timeout}, from, state) do
    params = %{name: tool, arguments: args || %{}}

    case state.config.transport do
      :stdio ->
        {id, state} = next_id(state)
        send_stdio(state, request(id, "tools/call", params))
        Process.send_after(self(), {:call_timeout, id}, timeout)
        {:noreply, %{state | pending: Map.put(state.pending, id, {:call, from})}}

      :http ->
        {id, state} = next_id(state)
        client = self()

        Task.Supervisor.start_child(AgentManager.TaskSupervisor, fn ->
          reply =
            case http_rpc(state, request(id, "tools/call", params), timeout) do
              {:ok, %{"result" => result}, _session} ->
                {:ok, tool_result(result)}

              {:ok, %{"error" => error}, _session} ->
                {:error, {:rpc, error}}

              {:error, {:http, 404, _}} = error ->
                send(client, {:http_failed, :session_expired}) && error

              {:error, reason} ->
                {:error, reason}
            end

          GenServer.reply(from, reply)
        end)

        {:noreply, state}
    end
  end

  # -- connecting ----------------------------------------------------------------

  defp connect(%{config: %{transport: :stdio}} = state) do
    with {:ok, state} <- open_port(state),
         {:ok, init, state} <- stdio_rpc(state, "initialize", init_params()),
         :ok <- send_stdio(state, notification("notifications/initialized")),
         {:ok, tools, state} <- list_tools_stdio(state, nil, []) do
      {:ok, %{state | server_info: init["serverInfo"], tools: tools}}
    end
  end

  defp connect(%{config: %{transport: :http}} = state) do
    state = %{state | session: nil}

    with {:ok, %{"result" => init}, session} <-
           http_rpc(state, request(0, "initialize", init_params()), @connect_timeout),
         state = %{state | session: session},
         {:ok, _, _} <-
           http_rpc(state, notification("notifications/initialized"), @connect_timeout),
         {:ok, tools} <- list_tools_http(state, nil, []) do
      {:ok, %{state | server_info: init["serverInfo"], tools: tools}}
    else
      {:ok, %{"error" => error}, _} -> {:error, {:rpc, error}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp init_params do
    %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{
        name: "agent_manager",
        version: to_string(Application.spec(:agent_manager, :vsn))
      }
    }
  end

  defp fail(state, reason) do
    Logger.warning("[mcp] #{state.config.name}: #{inspect(reason)} (retrying)")

    for {_id, {:call, from}} <- state.pending, do: GenServer.reply(from, {:error, :disconnected})
    close_port(state.port)

    delay = min(1_000 * Integer.pow(2, state.attempts), @max_backoff)
    Process.send_after(self(), :reconnect, delay)

    publish(%{
      state
      | status: :error,
        error: inspect(reason),
        pending: %{},
        port: nil,
        buffer: "",
        attempts: state.attempts + 1
    })
  end

  # -- stdio transport -----------------------------------------------------------

  defp close_port(port) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp close_port(_), do: :ok

  defp open_port(%{config: config} = state) do
    exe = System.find_executable(config.command) || config.command

    # On Windows, .bat/.cmd launchers (npx, elixir) must go through cmd.exe.
    {exe, args} =
      if match?({:win32, _}, :os.type()) and Path.extname(exe) in [".bat", ".cmd"],
        do: {System.find_executable("cmd"), ["/c", exe | config.args]},
        else: {exe, config.args}

    opts =
      [:binary, :exit_status, :use_stdio, :hide, {:line, 1_048_576}, args: args] ++
        if(config.env == %{},
          do: [],
          else: [env: Enum.map(config.env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)]
        ) ++
        if(config[:cwd], do: [cd: config.cwd], else: [])

    {:ok, %{state | port: Port.open({:spawn_executable, exe}, opts), buffer: ""}}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}, state}
  end

  defp send_stdio(%{port: port}, message) do
    Port.command(port, [Jason.encode!(message), "\n"])
    :ok
  end

  # Synchronous request used during the handshake: waits for the matching reply.
  defp stdio_rpc(state, method, params) do
    {id, state} = next_id(state)
    send_stdio(state, request(id, method, params))
    await(state, id, System.monotonic_time(:millisecond) + @connect_timeout)
  end

  defp await(%{port: port} = state, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await(%{state | buffer: state.buffer <> chunk}, id, deadline)

      {^port, {:data, {:eol, chunk}}} ->
        line = state.buffer <> chunk
        state = %{state | buffer: ""}

        case decode(line) do
          %{"id" => ^id, "result" => result} -> {:ok, result, state}
          %{"id" => ^id, "error" => error} -> {:error, {:rpc, error}, state}
          other -> state |> handle_message(other) |> await(id, deadline)
        end

      {^port, {:exit_status, code}} ->
        {:error, {:server_exited, code}, %{state | port: nil}}
    after
      remaining -> {:error, :handshake_timeout, state}
    end
  end

  defp list_tools_stdio(state, cursor, acc) do
    params = if cursor, do: %{cursor: cursor}, else: %{}

    with {:ok, result, state} <- stdio_rpc(state, "tools/list", params) do
      tools = acc ++ Enum.map(result["tools"] || [], &parse_tool/1)

      case result["nextCursor"] do
        nil -> {:ok, tools, state}
        next -> list_tools_stdio(state, next, tools)
      end
    end
  end

  defp handle_line(state, line), do: handle_message(state, decode(line))

  defp handle_message(state, %{"id" => id} = msg) when is_map_key(state.pending, id) do
    {entry, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case {entry, msg} do
      {{:call, from}, %{"result" => result}} ->
        GenServer.reply(from, {:ok, tool_result(result)})

      {{:call, from}, %{"error" => error}} ->
        GenServer.reply(from, {:error, {:rpc, error}})

      {:list_tools, %{"result" => result}} ->
        send(self(), {:tools_refreshed, Enum.map(result["tools"] || [], &parse_tool/1)})

      _ ->
        :ok
    end

    state
  end

  # Requests from the server: answer pings, refuse anything else we don't implement.
  defp handle_message(state, %{"id" => id, "method" => "ping"}) do
    send_stdio(state, %{jsonrpc: "2.0", id: id, result: %{}})
    state
  end

  defp handle_message(state, %{"id" => id, "method" => method}) do
    send_stdio(state, %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32601, message: "Method not supported: #{method}"}
    })

    state
  end

  defp handle_message(state, %{"method" => "notifications/tools/list_changed"}) do
    {id, state} = next_id(state)
    send_stdio(state, request(id, "tools/list", %{}))
    %{state | pending: Map.put(state.pending, id, :list_tools)}
  end

  defp handle_message(state, _other), do: state

  # -- http transport --------------------------------------------------------------

  defp http_rpc(state, message, timeout) do
    config = state.config

    headers =
      [{"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", @protocol}] ++
        Enum.to_list(config.headers) ++
        if(state.session, do: [{"mcp-session-id", state.session}], else: [])

    [
      url: config.url,
      json: message,
      headers: headers,
      receive_timeout: timeout,
      decode_body: false,
      retry: false
    ]
    |> Keyword.merge(config[:req_options] || [])
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: status} = resp} when status in 200..202 ->
        session = List.first(Req.Response.get_header(resp, "mcp-session-id")) || state.session

        cond do
          # notifications are acknowledged with 202 and no body
          not Map.has_key?(message, :id) -> {:ok, nil, session}
          true -> parse_http_reply(resp, message.id, session)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp parse_http_reply(resp, id, session) do
    content_type = resp |> Req.Response.get_header("content-type") |> List.first("")
    body = IO.iodata_to_binary(resp.body)

    messages =
      if String.starts_with?(content_type, "text/event-stream"),
        do: sse_messages(body),
        else: [decode(body)]

    case Enum.find(messages, &match?(%{"id" => ^id}, &1)) do
      nil -> {:error, {:no_reply, id}}
      reply -> {:ok, reply, session}
    end
  end

  # Server-Sent Events: events separated by blank lines, payload in `data:` lines.
  defp sse_messages(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      event
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(&1 |> String.trim_leading("data:") |> String.trim_leading()))
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&decode/1)
  end

  defp list_tools_http(state, cursor, acc) do
    params = if cursor, do: %{cursor: cursor}, else: %{}
    {id, _} = next_id(state)

    case http_rpc(state, request(id, "tools/list", params), @connect_timeout) do
      {:ok, %{"result" => result}, _} ->
        tools = acc ++ Enum.map(result["tools"] || [], &parse_tool/1)

        if next = result["nextCursor"],
          do: list_tools_http(state, next, tools),
          else: {:ok, tools}

      {:ok, %{"error" => error}, _} ->
        {:error, {:rpc, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- helpers ---------------------------------------------------------------------

  defp request(id, method, params), do: %{jsonrpc: "2.0", id: id, method: method, params: params}
  defp notification(method), do: %{jsonrpc: "2.0", method: method}

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp decode(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, msg} when is_map(msg) -> msg
      _ -> %{}
    end
  end

  defp parse_tool(tool) do
    %{
      name: tool["name"],
      description: tool["description"] || tool["title"] || "",
      input_schema: tool["inputSchema"] || %{"type" => "object", "properties" => %{}}
    }
  end

  @doc false
  # MCP results are a list of content parts; models get them as text.
  def tool_result(result) do
    text =
      (result["content"] || [])
      |> Enum.map(fn
        %{"type" => "text", "text" => text} -> text
        %{"type" => "resource", "resource" => %{"text" => text}} -> text
        %{"type" => "resource_link", "uri" => uri} -> "[resource: #{uri}]"
        %{"type" => type} -> "[#{type} content omitted]"
        _ -> ""
      end)
      |> Enum.join("\n")

    text =
      if text == "" and result["structuredContent"],
        do: Jason.encode!(result["structuredContent"]),
        else: text

    %{content: text, is_error: result["isError"] == true}
  end

  # The registry value is what `MCP.servers/0` and `MCP.tools/0` read, so the
  # pipeline never has to call into this process just to list tools.
  defp publish(state) do
    Registry.update_value(@registry, state.config.name, fn _ ->
      %{
        status: state.status,
        tools: state.tools,
        server_info: state.server_info,
        error: state.error,
        transport: state.config.transport
      }
    end)

    state
  end
end
