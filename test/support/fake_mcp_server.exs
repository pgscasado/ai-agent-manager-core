# A minimal MCP server over stdio, used by the tests (run with `elixir`).
# Speaks newline-delimited JSON-RPC 2.0 with no dependencies (Elixir's JSON).
#
# Tools: add(a, b) | fail | slow(ms) | crash (exits the process) |
#        add_tool (registers "added" and sends notifications/tools/list_changed)
defmodule FakeMCP do
  def loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case String.trim(line) do
          "" -> :ok
          json -> handle(JSON.decode!(json))
        end

        loop()
    end
  end

  defp send_msg(msg), do: IO.write(JSON.encode!(msg) <> "\n")
  defp reply(id, result), do: send_msg(%{jsonrpc: "2.0", id: id, result: result})

  defp text(id, text, error \\ false),
    do: reply(id, %{content: [%{type: "text", text: text}], isError: error})

  defp tools do
    base = [
      %{
        name: "add",
        description: "Adds two numbers",
        inputSchema: %{
          type: "object",
          properties: %{a: %{type: "number"}, b: %{type: "number"}},
          required: ["a", "b"]
        }
      },
      %{name: "fail", description: "Always fails", inputSchema: %{type: "object"}},
      %{
        name: "slow",
        description: "Sleeps",
        inputSchema: %{type: "object", properties: %{ms: %{type: "integer"}}}
      },
      %{name: "crash", description: "Exits the server", inputSchema: %{type: "object"}},
      %{name: "add_tool", description: "Adds a tool", inputSchema: %{type: "object"}}
    ]

    if :persistent_term.get(:added, false),
      do:
        base ++
          [%{name: "added", description: "Added at runtime", inputSchema: %{type: "object"}}],
      else: base
  end

  defp handle(%{"method" => "initialize", "id" => id}) do
    reply(id, %{
      protocolVersion: "2025-06-18",
      capabilities: %{tools: %{listChanged: true}},
      serverInfo: %{name: "fake-mcp", version: "1.0.0"}
    })
  end

  defp handle(%{"method" => "tools/list", "id" => id}), do: reply(id, %{tools: tools()})

  defp handle(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = params}) do
    args = params["arguments"] || %{}

    # each call in its own process, so slow calls overlap like a real server's
    spawn(fn ->
      case name do
        "add" ->
          text(id, to_string(args["a"] + args["b"]))

        "fail" ->
          text(id, "something went wrong", true)

        "slow" ->
          Process.sleep(args["ms"] || 300) && text(id, "done")

        "crash" ->
          System.halt(1)

        "add_tool" ->
          :persistent_term.put(:added, true)
          text(id, "ok")
          send_msg(%{jsonrpc: "2.0", method: "notifications/tools/list_changed"})

        other ->
          send_msg(%{
            jsonrpc: "2.0",
            id: id,
            error: %{code: -32602, message: "unknown tool #{other}"}
          })
      end
    end)
  end

  defp handle(%{"method" => "ping", "id" => id}), do: reply(id, %{})
  defp handle(_notification), do: :ok
end

FakeMCP.loop()
