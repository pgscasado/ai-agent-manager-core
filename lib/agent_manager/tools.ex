defmodule AgentManager.Tools do
  @moduledoc """
  Tools a model can call while answering: local Elixir modules and the tools
  of connected MCP servers, behind one interface.

  Every tool has an **id** used for configuration and a **name** the model sees:

  | source | id | model-facing name |
  |---|---|---|
  | local module | `local:current_time` | `current_time` |
  | MCP server `crm`, tool `find-customer` | `mcp:crm/find-customer` | `crm__find-customer` |

  Bots opt in through `model_config.tools`, a list of ids or globs:
  `["local:*", "mcp:crm/*", "mcp:docs/search"]`. An empty list (the default)
  means no tools, and the answer pipeline behaves as it did before tools.

  Local tools are listed in config and implement `AgentManager.Tools.Tool`:

      config :agent_manager, AgentManager.Tools,
        local: [AgentManager.Tools.CurrentTime, AgentManager.Tools.SearchKnowledge],
        timeout: 30_000
  """

  alias AgentManager.MCP

  defmodule Spec do
    @moduledoc "A tool as offered to a model."
    defstruct [:id, :name, :description, :input_schema, :source]
  end

  @default_local [AgentManager.Tools.CurrentTime, AgentManager.Tools.SearchKnowledge]

  @doc "Every tool currently available (local + ready MCP servers)."
  def available do
    local =
      for mod <- config(:local, @default_local) do
        %Spec{
          id: "local:" <> mod.name(),
          name: model_name(mod.name()),
          description: mod.description(),
          input_schema: mod.input_schema(),
          source: {:local, mod}
        }
      end

    remote =
      for tool <- MCP.tools() do
        %Spec{
          id: "mcp:#{tool.server}/#{tool.name}",
          name: model_name("#{tool.server}__#{tool.name}"),
          description: tool.description,
          input_schema: tool.input_schema,
          source: {:mcp, tool.server, tool.name}
        }
      end

    local ++ remote
  end

  @doc "The tools `bot` may use, according to its `model_config.tools` patterns."
  def for_bot(%{model_config: %{tools: [_ | _] = patterns}}) do
    Enum.filter(available(), fn spec -> Enum.any?(patterns, &matches?(&1, spec.id)) end)
  end

  def for_bot(_bot), do: []

  @doc false
  def matches?("*", _id), do: true

  def matches?(pattern, id) do
    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(id, String.trim_trailing(pattern, "*")),
      else: pattern == id
  end

  @doc "Definitions in the provider-neutral shape `ChatModel` adapters take."
  def definitions(specs) do
    Enum.map(specs, &%{name: &1.name, description: &1.description, input_schema: &1.input_schema})
  end

  @doc """
  Runs a round of tool calls concurrently (each in a supervised task with a
  timeout). Returns one result per call, in order:
  `%{call, spec, content, is_error, duration_ms}`.
  """
  def execute_all(calls, specs, ctx) do
    by_name = Map.new(specs, &{&1.name, &1})
    timeout = config(:timeout, 30_000)

    AgentManager.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      calls,
      &execute(&1, Map.get(by_name, &1.name), ctx, timeout),
      timeout: timeout + 2_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(calls)
    |> Enum.map(fn
      {{:ok, result}, _call} ->
        result

      {{:exit, reason}, call} ->
        %{
          call: call,
          spec: Map.get(by_name, call.name),
          content: "Tool failed: #{inspect(reason)}",
          is_error: true,
          duration_ms: timeout
        }
    end)
  end

  defp execute(call, nil, _ctx, _timeout) do
    %{
      call: call,
      spec: nil,
      content: "Unknown tool: #{call.name}",
      is_error: true,
      duration_ms: 0
    }
  end

  defp execute(call, spec, ctx, timeout) do
    started = System.monotonic_time(:millisecond)

    {content, is_error} =
      case run(spec.source, call.arguments, ctx, timeout) do
        {:ok, %{content: content, is_error: is_error}} -> {content, is_error}
        {:ok, text} when is_binary(text) -> {text, false}
        {:ok, other} -> {Jason.encode!(other), false}
        {:error, reason} -> {"Tool error: #{inspect(reason)}", true}
      end

    %{
      call: call,
      spec: spec,
      content: content,
      is_error: is_error,
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  rescue
    e ->
      %{
        call: call,
        spec: spec,
        content: "Tool raised: #{Exception.message(e)}",
        is_error: true,
        duration_ms: 0
      }
  end

  defp run({:local, mod}, args, ctx, _timeout), do: mod.call(args, ctx)

  defp run({:mcp, server, tool}, args, _ctx, timeout),
    do: MCP.call_tool(server, tool, args, timeout)

  # Providers accept [a-zA-Z0-9_-]{1,64} for tool names.
  defp model_name(name) do
    name |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> String.slice(0, 64)
  end

  defp config(key, default),
    do: Application.get_env(:agent_manager, __MODULE__, [])[key] || default
end

defmodule AgentManager.Tools.Tool do
  @moduledoc """
  A local tool. `call/2` gets the decoded arguments and the pipeline context
  (so it can use `ctx.bot`, `ctx.input.user_id`, ...), and returns text, any
  JSON-encodable term, or `{:error, reason}`.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback call(arguments :: map(), ctx :: AgentManager.Pipeline.Context.t()) ::
              {:ok, String.t() | term()} | {:error, term()}
end

defmodule AgentManager.Tools.CurrentTime do
  @moduledoc "Current date and time, optionally in a UTC offset."
  @behaviour AgentManager.Tools.Tool

  @impl true
  def name, do: "current_time"

  @impl true
  def description,
    do:
      "Returns the current date and time (ISO 8601). Use it for questions about today, opening hours right now, deadlines."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "utc_offset_hours" => %{
          "type" => "number",
          "description" => "Offset from UTC, e.g. -3 for Brasília."
        }
      }
    }
  end

  @impl true
  def call(args, _ctx) do
    offset = round((args["utc_offset_hours"] || 0) * 3600)

    {:ok,
     DateTime.utc_now()
     |> DateTime.add(offset, :second)
     |> DateTime.truncate(:second)
     |> DateTime.to_iso8601()
     |> Kernel.<>(" (UTC#{format_offset(offset)})")}
  end

  defp format_offset(0), do: ""
  defp format_offset(s) when s > 0, do: "+#{div(s, 3600)}"
  defp format_offset(s), do: "#{div(s, 3600)}"
end

defmodule AgentManager.Tools.SearchKnowledge do
  @moduledoc "Lets the model run extra searches over its own bot's knowledge base."
  @behaviour AgentManager.Tools.Tool

  @impl true
  def name, do: "search_knowledge"

  @impl true
  def description,
    do:
      "Searches this assistant's knowledge base and returns the most relevant passages. Use it when the provided context doesn't answer the question."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "What to look for."},
        "limit" => %{"type" => "integer", "description" => "Max passages (1-10).", "default" => 5}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def call(%{"query" => query} = args, ctx) do
    limit = args["limit"] |> Kernel.||(5) |> max(1) |> min(10)

    with {:ok, hits} <-
           AgentManager.Knowledge.search(
             ctx.bot,
             query,
             limit,
             AgentManager.Pipeline.Context.model_opts(ctx)
           ) do
      {:ok,
       hits
       |> Enum.map(&AgentManager.Attachments.mask(&1.segment))
       |> Enum.join("\n---\n")
       |> then(&if(&1 == "", do: "No results.", else: &1))}
    end
  end

  def call(_args, _ctx), do: {:error, "query is required"}
end
