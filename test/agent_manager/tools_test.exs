defmodule AgentManager.ToolsTest do
  use AgentManager.Case

  alias AgentManager.{Bots, Conversations, Events, MCP, Store, Tools}
  alias AgentManager.Models.Adapters.{Anthropic, OpenAI}

  @server_script Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp start_stdio_server(name) do
    {:ok, _} =
      MCP.start_server(%{
        name: name,
        transport: :stdio,
        command: "elixir",
        args: [@server_script]
      })

    on_exit(fn -> MCP.stop_server(name) end)

    wait_until(
      fn -> match?([%{status: :ready}], Enum.filter(MCP.servers(), &(&1.name == name))) end,
      30_000
    )
  end

  describe "MCP over stdio" do
    setup do
      start_stdio_server("fake")
      :ok
    end

    test "handshake, tool listing and calls" do
      assert [%{name: "fake", status: :ready, tools: 5, server_info: %{"name" => "fake-mcp"}}] =
               Enum.filter(MCP.servers(), &(&1.name == "fake"))

      assert {:ok, %{content: "5", is_error: false}} =
               MCP.call_tool("fake", "add", %{"a" => 2, "b" => 3})

      assert {:ok, %{content: "something went wrong", is_error: true}} =
               MCP.call_tool("fake", "fail", %{})

      assert {:error, {:rpc, %{"code" => -32602}}} = MCP.call_tool("fake", "nope", %{})
      assert {:error, {:unknown_server, "missing"}} = MCP.call_tool("missing", "add", %{})
    end

    test "calls to one server run concurrently" do
      {micros, results} =
        :timer.tc(fn ->
          1..4
          |> Enum.map(fn _ ->
            Task.async(fn -> MCP.call_tool("fake", "slow", %{"ms" => 400}) end)
          end)
          |> Enum.map(&Task.await/1)
        end)

      assert Enum.all?(results, &match?({:ok, %{content: "done"}}, &1))
      assert micros < 1_200_000
    end

    test "a crashed server is reported and reconnected automatically" do
      pid = MCP.whereis("fake")
      assert {:error, :disconnected} = MCP.call_tool("fake", "crash", %{})
      assert [%{status: :error}] = Enum.filter(MCP.servers(), &(&1.name == "fake"))

      wait_until(
        fn -> match?([%{status: :ready}], Enum.filter(MCP.servers(), &(&1.name == "fake"))) end,
        30_000
      )

      # same supervised client process, new OS process underneath
      assert MCP.whereis("fake") == pid
      assert {:ok, %{content: "7"}} = MCP.call_tool("fake", "add", %{"a" => 3, "b" => 4})
    end

    test "tools/list_changed refreshes the tool list" do
      refute Enum.any?(MCP.tools(), &(&1.name == "added"))
      assert {:ok, _} = MCP.call_tool("fake", "add_tool", %{})
      wait_until(fn -> Enum.any?(MCP.tools(), &(&1.name == "added")) end)
    end

    test "tools are exposed with ids and provider-safe names" do
      ids = Enum.map(Tools.available(), & &1.id)
      assert "local:current_time" in ids and "mcp:fake/add" in ids
      assert %{name: "fake__add"} = Enum.find(Tools.available(), &(&1.id == "mcp:fake/add"))

      bot = %{model_config: %{tools: ["mcp:fake/a*", "local:current_time"]}}

      assert Enum.sort(Enum.map(Tools.for_bot(bot), & &1.id)) == [
               "local:current_time",
               "mcp:fake/add",
               "mcp:fake/add_tool"
             ]

      assert Tools.for_bot(%{model_config: %{tools: []}}) == []
    end
  end

  describe "MCP over Streamable HTTP" do
    setup {Req.Test, :set_req_test_to_shared}

    test "session header, SSE replies and tool calls" do
      test_pid = self()

      Req.Test.stub(:mcp_http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        msg = Jason.decode!(body)

        send(
          test_pid,
          {:mcp_http, msg["method"], Plug.Conn.get_req_header(conn, "mcp-session-id")}
        )

        assert Plug.Conn.get_req_header(conn, "accept") == ["application/json, text/event-stream"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]

        case msg do
          %{"method" => "initialize", "id" => id} ->
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "session-1")
            |> Req.Test.json(%{
              jsonrpc: "2.0",
              id: id,
              result: %{
                protocolVersion: "2025-06-18",
                capabilities: %{tools: %{}},
                serverInfo: %{name: "remote"}
              }
            })

          %{"method" => "notifications/initialized"} ->
            Plug.Conn.send_resp(conn, 202, "")

          %{"method" => "tools/list", "id" => id} ->
            Req.Test.json(conn, %{
              jsonrpc: "2.0",
              id: id,
              result: %{
                tools: [
                  %{name: "lookup", description: "Looks up", inputSchema: %{type: "object"}}
                ]
              }
            })

          %{"method" => "tools/call", "id" => id, "params" => %{"arguments" => args}} ->
            # reply as a Server-Sent Events stream, with a progress notification first
            sse =
              "event: message\ndata: " <>
                Jason.encode!(%{
                  jsonrpc: "2.0",
                  method: "notifications/progress",
                  params: %{progress: 1}
                }) <>
                "\n\n" <>
                "event: message\ndata: " <>
                Jason.encode!(%{
                  jsonrpc: "2.0",
                  id: id,
                  result: %{content: [%{type: "text", text: "found #{args["q"]}"}]}
                }) <> "\n\n"

            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, sse)
        end
      end)

      {:ok, _} =
        MCP.start_server(%{
          name: "remote",
          transport: :http,
          url: "https://remote.example.com/mcp",
          headers: %{"authorization" => "Bearer secret"},
          req_options: [plug: {Req.Test, :mcp_http}]
        })

      on_exit(fn -> MCP.stop_server("remote") end)

      wait_until(fn ->
        match?([%{status: :ready, tools: 1}], Enum.filter(MCP.servers(), &(&1.name == "remote")))
      end)

      assert_receive {:mcp_http, "initialize", []}
      assert_receive {:mcp_http, "notifications/initialized", ["session-1"]}
      assert_receive {:mcp_http, "tools/list", ["session-1"]}

      assert {:ok, %{content: "found cats", is_error: false}} =
               MCP.call_tool("remote", "lookup", %{"q" => "cats"})

      assert_receive {:mcp_http, "tools/call", ["session-1"]}
    end
  end

  describe "tool calling in the answer pipeline" do
    setup do
      start_stdio_server("fake")

      bot =
        create_bot!()
        |> train!(%{
          "bot_name" => "Loja",
          "source_text" =>
            "Aceitamos pagamento em cartão de crédito, débito, pix e boleto bancário em todas as compras do site."
        })

      {:ok, bot: bot}
    end

    test "the model calls local and MCP tools, gets results, then answers", %{bot: bot} do
      {:ok, bot} =
        Bots.update(bot, %{"model_config" => %{"tools" => ["local:current_time", "mcp:fake/add"]}})

      test_pid = self()

      Fake.set_responder(fn messages, opts ->
        if opts[:json] do
          send(test_pid, {:offered, Enum.map(opts[:tools] || [], & &1.name)})

          case Enum.filter(messages, &(&1.role == :tool)) do
            [] ->
              {:ok,
               %{
                 content: "",
                 tool_calls: [
                   %{id: "c1", name: "fake__add", arguments: %{"a" => 40, "b" => 2}},
                   %{id: "c2", name: "current_time", arguments: %{}}
                 ]
               }}

            results ->
              sum = Enum.find(results, &(&1.tool_call_id == "c1")).content

              {:ok,
               Jason.encode!(%{response: "A soma é #{sum}.", offer_human_attendance: "false"})}
          end
        else
          {:ok, "x"}
        end
      end)

      Events.subscribe({:bot, bot.id})
      assert {:ok, answer, ctx} = Conversations.ask(bot, "u", "Quanto é 40 + 2?")
      assert answer.response == "A soma é 42."
      assert answer.metadata.tools_used == ["mcp:fake/add", "local:current_time"]

      assert_receive {:offered, offered}
      assert Enum.sort(offered) == ["current_time", "fake__add"]
      assert_event("tool.called")
      completed = assert_event("tool.completed")
      assert completed.payload.is_error == false
      assert ctx.usage.total_tokens > 0

      # only the question and final answer enter the conversation history
      wait_until(fn -> length(Store.impl().list_messages(bot.id, "u", [])) == 1 end)
    end

    test "tool errors go back to the model, which can still answer", %{bot: bot} do
      {:ok, bot} = Bots.update(bot, %{"model_config" => %{"tools" => ["mcp:fake/*"]}})

      Fake.set_responder(fn messages, opts ->
        cond do
          not opts[:json] ->
            {:ok, "x"}

          r = Enum.find(messages, &(&1.role == :tool)) ->
            {:ok, Jason.encode!(%{response: "Falhou: #{r.content} (erro=#{r.is_error})"})}

          true ->
            {:ok, %{content: "", tool_calls: [%{id: "c1", name: "fake__fail", arguments: %{}}]}}
        end
      end)

      assert {:ok, %{response: "Falhou: something went wrong (erro=true)"}, _} =
               Conversations.ask(bot, "u", "tente")
    end

    test "tool rounds are capped", %{bot: bot} do
      {:ok, bot} = Bots.update(bot, %{"model_config" => %{"tools" => ["mcp:fake/add"]}})
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Fake.set_responder(fn _messages, opts ->
        if opts[:tools] do
          Agent.update(counter, &(&1 + 1))

          {:ok,
           %{
             content: "",
             tool_calls: [%{id: "c", name: "fake__add", arguments: %{"a" => 1, "b" => 1}}]
           }}
        else
          {:ok, "Problema técnico."}
        end
      end)

      assert {:ok, answer, _} = Conversations.ask(bot, "u", "loop")
      assert answer.error and answer.start_attendance
      # 5 tool rounds + 1 final attempt, repeated once by the step's retry
      assert Agent.get(counter, & &1) == 12
    end

    test "bots without tools are not offered any", %{bot: bot} do
      test_pid = self()

      Fake.set_responder(fn _m, opts ->
        send(test_pid, {:tools, opts[:tools]}) && {:ok, ~s({"response": "ok"})}
      end)

      assert {:ok, _, _} = Conversations.ask(bot, "u", "oi")
      assert_receive {:tools, nil}
    end
  end

  test "current_time renders local time with a real ISO 8601 offset" do
    utc = ~U[2026-09-28 14:23:19.123Z]
    assert AgentManager.Tools.CurrentTime.at(utc, 0) == "2026-09-28T14:23:19Z"
    assert AgentManager.Tools.CurrentTime.at(utc, -3) == "2026-09-28T11:23:19-03:00"
    assert AgentManager.Tools.CurrentTime.at(utc, 5.5) == "2026-09-28T19:53:19+05:30"

    {:ok, iso} = AgentManager.Tools.CurrentTime.call(%{"utc_offset_hours" => -3}, nil)
    assert {:ok, parsed, -10_800} = DateTime.from_iso8601(iso)
    assert abs(DateTime.diff(parsed, DateTime.utc_now())) < 5
  end

  describe "adapter wire formats for tools" do
    @tools [%{name: "fake__add", description: "Adds", input_schema: %{"type" => "object"}}]
    @history [
      %{role: :system, content: "sys"},
      %{role: :user, content: "2+3?"},
      %{
        role: :assistant,
        content: "",
        tool_calls: [
          %{id: "t1", name: "fake__add", arguments: %{"a" => 2, "b" => 3}},
          %{id: "t2", name: "fake__add", arguments: %{"a" => 1, "b" => 1}}
        ]
      },
      %{role: :tool, tool_call_id: "t1", name: "fake__add", content: "5", is_error: false},
      %{role: :tool, tool_call_id: "t2", name: "fake__add", content: "2", is_error: false}
    ]

    test "OpenAI: function tools out, tool_calls in, role=tool results" do
      Req.Test.stub(:openai_tools, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        assert [
                 %{
                   "type" => "function",
                   "function" => %{"name" => "fake__add", "parameters" => %{"type" => "object"}}
                 }
               ] = req["tools"]

        assert %{
                 "role" => "assistant",
                 "tool_calls" => [%{"id" => "t1", "function" => %{"arguments" => args}} | _]
               } = Enum.at(req["messages"], 2)

        assert Jason.decode!(args) == %{"a" => 2, "b" => 3}

        assert %{"role" => "tool", "tool_call_id" => "t1", "content" => "5"} =
                 Enum.at(req["messages"], 3)

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "t9",
                    "type" => "function",
                    "function" => %{"name" => "fake__add", "arguments" => ~s({"a":1,"b":2})}
                  }
                ]
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      assert {:ok,
              %{
                content: "",
                tool_calls: [%{id: "t9", name: "fake__add", arguments: %{"a" => 1, "b" => 2}}]
              }} =
               OpenAI.chat(@history,
                 model: "m",
                 tools: @tools,
                 req_options: [plug: {Req.Test, :openai_tools}]
               )
    end

    test "Anthropic: tool_use blocks in, one user turn with all tool_results out" do
      Req.Test.stub(:anthropic_tools, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        assert [%{"name" => "fake__add", "input_schema" => %{"type" => "object"}}] = req["tools"]
        assert [%{"role" => "user"}, assistant, results] = req["messages"]

        assert [
                 %{"type" => "tool_use", "id" => "t1", "input" => %{"a" => 2}},
                 %{"type" => "tool_use", "id" => "t2"}
               ] = assistant["content"]

        assert %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "5"},
                   %{"tool_use_id" => "t2"}
                 ]
               } = results

        Req.Test.json(conn, %{
          "stop_reason" => "tool_use",
          "content" => [
            %{"type" => "text", "text" => "Let me add."},
            %{
              "type" => "tool_use",
              "id" => "tu",
              "name" => "fake__add",
              "input" => %{"a" => 4, "b" => 4}
            }
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      assert {:ok,
              %{
                content: "Let me add.",
                tool_calls: [%{id: "tu", name: "fake__add", arguments: %{"a" => 4, "b" => 4}}]
              }} =
               Anthropic.chat(@history,
                 model: "m",
                 tools: @tools,
                 req_options: [plug: {Req.Test, :anthropic_tools}]
               )
    end
  end
end
