defmodule AgentManager.ProviderSwapTest do
  @moduledoc """
  One conversation, three providers, each speaking its real wire format
  (stubbed at the HTTP layer): Gemini (OpenAI-compatible endpoint) -> OpenAI
  -> Anthropic. Proves swapping is a config change: the pipeline, history and
  usage accounting do not depend on which provider answered.
  """
  use AgentManager.Case

  alias AgentManager.{Bots, Conversations, Store}
  alias AgentManager.Models.Adapters.{Anthropic, OpenAI}

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    original = Application.get_env(:agent_manager, AgentManager.Models)

    providers = [
      fake: [adapter: Fake],
      gemini: [
        adapter: OpenAI,
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        api_key: "global-gemini-key",
        req_options: [plug: {Req.Test, :gemini_wire}]
      ],
      openai: [
        adapter: OpenAI,
        api_key: "global-openai-key",
        req_options: [plug: {Req.Test, :openai_wire}]
      ],
      # no global Anthropic key: bots must bring their own
      anthropic: [
        adapter: Anthropic,
        api_key: nil,
        req_options: [plug: {Req.Test, :anthropic_wire}]
      ]
    ]

    Application.put_env(
      :agent_manager,
      AgentManager.Models,
      Keyword.put(original, :providers, providers)
    )

    on_exit(fn -> Application.put_env(:agent_manager, AgentManager.Models, original) end)

    test_pid = self()

    # OpenAI wire format, used by both OpenAI and Gemini's compatible endpoint.
    openai_like = fn label ->
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        send(
          test_pid,
          {:wire, label, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), req}
        )

        Req.Test.json(conn, %{
          "model" => req["model"],
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" =>
                  Jason.encode!(%{response: "#{label} answered", offer_human_attendance: "false"})
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10}
        })
      end
    end

    Req.Test.stub(:gemini_wire, openai_like.("gemini"))
    Req.Test.stub(:openai_wire, openai_like.("openai"))

    Req.Test.stub(:anthropic_wire, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      key = Plug.Conn.get_req_header(conn, "x-api-key")
      send(test_pid, {:wire, "anthropic", conn.request_path, key, req})

      if key == [""] do
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "type" => "error",
          "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
        })
      else
        Req.Test.json(conn, %{
          "model" => req["model"],
          "stop_reason" => "end_turn",
          "content" => [
            %{
              "type" => "text",
              "text" => ~s({"response": "anthropic answered", "offer_human_attendance": "false"})
            }
          ],
          "usage" => %{"input_tokens" => 120, "output_tokens" => 12}
        })
      end
    end)

    bot =
      create_bot!()
      |> train!(%{
        "bot_name" => "Loja",
        "source_text" =>
          "Aceitamos pagamento em cartão de crédito, débito, pix e boleto bancário em todas as compras do site."
      })

    {:ok, bot: bot}
  end

  defp use_model(bot, spec, keys) do
    {:ok, bot} = Bots.update(bot, %{"model_config" => %{"llm_model" => spec, "api_keys" => keys}})
    bot
  end

  test "one conversation moves across Gemini, OpenAI and Anthropic", %{bot: bot} do
    # 1. Gemini, with the bot's own key
    bot = use_model(bot, "gemini:gemini-3.8-flash", %{"gemini" => "bot-gemini-key"})

    assert {:ok, %{response: "gemini answered"}, _} =
             Conversations.ask(bot, "u", "Quais formas de pagamento?")

    assert_receive {:wire, "gemini", "/v1beta/openai/chat/completions", ["Bearer bot-gemini-key"],
                    req}

    assert req["model"] == "gemini-3.8-flash"
    assert req["response_format"] == %{"type" => "json_object"}
    assert hd(req["messages"])["content"] =~ "pix"

    # 2. OpenAI, falling back to the global key; history from Gemini's turn is carried over
    bot = use_model(bot, "openai:gpt-4o", %{})
    assert {:ok, %{response: "openai answered"}, _} = Conversations.ask(bot, "u", "E parcelam?")

    assert_receive {:wire, "openai", "/v1/chat/completions", ["Bearer global-openai-key"], req}
    assert req["model"] == "gpt-4o"
    contents = Enum.map(req["messages"], & &1["content"])
    assert "Quais formas de pagamento?" in contents
    assert Enum.any?(contents, &(&1 =~ "gemini answered"))

    # 3. Anthropic: system prompt moved to `system`, alternating turns, whole history kept
    bot = use_model(bot, "anthropic:claude-opus-5", %{"anthropic" => "bot-anthropic-key"})
    assert {:ok, %{response: "anthropic answered"}, _} = Conversations.ask(bot, "u", "Obrigado!")

    assert_receive {:wire, "anthropic", "/v1/messages", ["bot-anthropic-key"], req}
    assert req["model"] == "claude-opus-5"
    assert req["system"] =~ "pix"
    roles = Enum.map(req["messages"], & &1["role"])
    assert roles == ["user", "assistant", "user", "assistant", "user"]
    assert Enum.any?(req["messages"], &(&1["content"] =~ "openai answered"))

    # Usage is recorded the same way whoever answered.
    wait_until(fn -> length(Store.Memory.llm_calls()) >= 3 end)
    models = Store.Memory.llm_calls() |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort()
    assert models == ["anthropic:claude-opus-5", "gemini:gemini-3.8-flash", "openai:gpt-4o"]
    wait_until(fn -> Bots.get(bot.id).total_tokens == 110 + 110 + 132 end)
  end

  test "swapping to a provider without a key degrades to a human handoff, not a crash", %{
    bot: bot
  } do
    bot = use_model(bot, "anthropic:claude-opus-5", %{})
    assert {:ok, answer, _} = Conversations.ask(bot, "u", "Oi?")
    assert answer.error and answer.start_attendance
    assert_receive {:wire, "anthropic", "/v1/messages", [""], _}

    # the conversation keeps working once the bot points at a usable provider
    bot = use_model(bot, "gemini:gemini-3.8-flash", %{})

    assert {:ok, %{response: "gemini answered", error: false}, _} =
             Conversations.ask(bot, "u", "Oi de novo?")

    assert_receive {:wire, "gemini", _, ["Bearer global-gemini-key"], _}
  end

  test "Gemini thought signatures on tool calls are sent back unchanged" do
    test_pid = self()
    signature = %{"google" => %{"thought_signature" => "c2lnbmF0dXJl"}}

    Req.Test.stub(:signature_wire, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:request, request})

      if Enum.any?(request["messages"], &(&1["role"] == "tool")) do
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "done"}}]})
      else
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "extra_content" => signature,
                    "function" => %{"name" => "booking_available_slots", "arguments" => "{}"}
                  }
                ]
              }
            }
          ]
        })
      end
    end)

    opts = [
      model: "gemini-3.5-flash-lite",
      api_key: "k",
      req_options: [plug: {Req.Test, :signature_wire}],
      tools: [%{name: "booking_available_slots", description: "slots", input_schema: %{}}],
      json: true
    ]

    user = [%{role: :user, content: "slots?"}]
    {:ok, %{tool_calls: [call]}} = OpenAI.chat(user, opts)
    assert_receive {:request, first}
    # with tools, JSON output isn't forced (Gemini would keep calling the tool)
    refute Map.has_key?(first, "response_format")

    followup =
      user ++
        [
          %{role: :assistant, content: nil, tool_calls: [call]},
          %{role: :tool, tool_call_id: "call_1", name: call.name, content: "[]"}
        ]

    {:ok, %{content: "done"}} = OpenAI.chat(followup, opts)
    assert_receive {:request, %{"messages" => messages}}

    assert [%{"tool_calls" => [sent]}] = Enum.filter(messages, &(&1["role"] == "assistant"))
    assert sent["extra_content"] == signature
    assert sent["id"] == "call_1" and sent["function"]["name"] == "booking_available_slots"
  end
end
