defmodule AgentManagerWeb.ApiTest do
  use AgentManagerWeb.ConnCase
  import Phoenix.ChannelTest

  alias AgentManager.Events

  @create %{
    "identifier" => "loja-1",
    "openai_config" => %{
      "llm_model" => "gpt-3.5-turbo",
      "message_buffer" => 3,
      "openai_key" => "sk-legacy-key-123456",
      "temp_content" => %{
        "bot_name" => "Loja",
        "source_text" =>
          "Aceitamos pagamento em cartão de crédito, débito e pix em todas as compras."
      }
    }
  }

  defp create_and_train(conn) do
    Events.subscribe("training.completed")
    body = conn |> post("/bot", @create) |> json_response(200)
    assert_receive {:event, %{type: "training.completed"}}, 5_000
    wait_until(fn -> AgentManager.Bots.get(body["id"]).training_info.status == :FINISHED end)
    body
  end

  test "legacy create payload is accepted, trained, and secrets are not echoed", %{conn: conn} do
    body = create_and_train(conn)
    assert body["training_status"] == "ON_TRAINING"
    assert body["model_config"]["api_keys"] == %{"openai" => "sk-le...3456"}

    shown = conn |> get("/1.0/bot/loja-1") |> json_response(200)
    assert shown["training_info"]["status"] == "FINISHED"
    assert shown["model_config"]["content"]["bot_name"] == "Loja"

    [status] = conn |> post("/bot/training", %{"ids" => [body["id"]]}) |> json_response(200)
    assert status["status"] == "FINISHED"
  end

  test "get_answer returns the 1.0 response shape", %{conn: conn} do
    %{"id" => id} = create_and_train(conn)

    # the legacy model name no longer resolves in test config; point it at the fake provider
    conn |> patch("/bot/#{id}/ai/fake:chat") |> json_response(200)

    body =
      conn
      |> post("/message/#{id}/get_answer", %{"text" => "Aceitam pix?", "user_id" => "u1"})
      |> json_response(200)

    assert %{
             "type" => "default",
             "response" => "Echo: Aceitam pix?",
             "start_attendance" => "false",
             "asked_for_attendance" => "false"
           } = body

    assert body["metadata"]["is_bot_disabled"] == "false"
  end

  test "validation, not found and forbidden fields", %{conn: conn} do
    assert %{"message" => "Bot not found"} = conn |> get("/bot/nope") |> json_response(404)

    assert %{"message" => "text is required"} =
             conn |> post("/message/x/get_answer", %{"user_id" => "u"}) |> json_response(400)

    %{"id" => id} = conn |> post("/bot", %{"name" => "x"}) |> json_response(200)

    assert %{"message" => "Unknown model provider: nope"} =
             conn |> patch("/bot/#{id}/models", %{"llm_model" => "nope:x"}) |> json_response(400)
  end

  test "field patches coerce their values", %{conn: conn} do
    %{"id" => id} = conn |> post("/bot", %{"name" => "x"}) |> json_response(200)

    assert %{"disabled" => true} = conn |> patch("/bot/#{id}/disabled/yes") |> json_response(200)
    assert %{"disabled" => false} = conn |> patch("/bot/#{id}/disabled/off") |> json_response(200)

    assert %{"user_history_time" => 30} =
             conn |> patch("/bot/#{id}/user_history_time/30") |> json_response(200)

    assert %{"start_message" => "Olá"} =
             conn |> patch("/bot/#{id}/start_message/Olá") |> json_response(200)

    assert %{"start_message" => nil} =
             conn |> patch("/bot/#{id}/start_message/:unset") |> json_response(200)

    body =
      conn
      |> patch("/bot/#{id}/access_control/true", %{"access_control_message" => "Restrito"})
      |> json_response(200)

    assert body["access_control"] and body["access_control_message"] == "Restrito"

    body =
      conn
      |> patch("/bot/#{id}/job_timings", %{"nps" => 10, "inactive" => 5})
      |> json_response(200)

    assert body["job_timings"] == %{"inactive_minutes" => 5, "nps_minutes" => 10}
  end

  test "models can be swapped per bot", %{conn: conn} do
    %{"id" => id} = conn |> post("/bot", %{"name" => "x"}) |> json_response(200)

    body =
      conn
      |> patch("/bot/#{id}/models", %{
        "llm_model" => "alt:big",
        "utility_model" => "fake:small",
        "api_keys" => %{"alt" => "key-1234567890"}
      })
      |> json_response(200)

    assert body["model_config"]["llm_model"] == "alt:big"
    assert body["model_config"]["utility_model"] == "fake:small"
    assert body["model_config"]["api_keys"] == %{"alt" => "key-1...7890"}
  end

  test "manual messages, topK, generate_prompt, pagination and introspection", %{conn: conn} do
    %{"id" => id} = create_and_train(conn)

    assert %{"message" => "Message inserted"} =
             conn
             |> post("/message/#{id}/bot_message", %{
               "text" => "Oferta!",
               "user_id" => "u",
               "flags" => ["nps_minutes"]
             })
             |> json_response(200)

    assert %{"topK" => [%{"segment" => segment} | _]} =
             conn |> post("/bot/#{id}/topK", %{"text" => "pix"}) |> json_response(200)

    assert segment =~ "pix"

    %{"prompt" => prompt, "trace" => trace} =
      conn
      |> get("/debug/#{id}/generate_prompt", %{"text" => "aceitam pix?", "user_id" => "u"})
      |> json_response(200)

    assert [
             %{"role" => "system"},
             %{"role" => "system"},
             %{"role" => "assistant", "content" => bot_msg},
             %{"role" => "user"}
           ] = prompt

    assert bot_msg =~ "Oferta!"
    refute Enum.any?(trace, &(&1["step"] =~ "Generate"))

    conn |> post("/bot", %{"name" => "second"}) |> json_response(200)
    page = conn |> get("/bot", %{"size" => "1"}) |> json_response(200)
    assert page["total_documents"] == 2 and page["total_pages"] == 2 and length(page["bots"]) == 1

    assert %{"answer" => [_ | _], "training" => [_ | _]} =
             conn |> get("/pipelines") |> json_response(200)

    assert %{"providers" => [_ | _]} = conn |> get("/models") |> json_response(200)

    assert %{"tokens" => n} =
             conn |> post("/debug/tokens", %{"text" => "hello world"}) |> json_response(200)

    assert n > 0

    assert [%{"label" => "pt"}] =
             conn |> get("/debug/language", %{"text" => "oi"}) |> json_response(200)
  end

  test "the bot channel streams that bot's events", %{conn: conn} do
    %{"id" => id} = conn |> post("/bot", %{"name" => "x"}) |> json_response(200)

    {:ok, _, _socket} =
      AgentManagerWeb.UserSocket
      |> socket(nil, %{})
      |> subscribe_and_join(AgentManagerWeb.BotChannel, "bot:#{id}")

    conn |> patch("/bot/#{id}/disabled/true") |> json_response(200)
    assert_push "bot.updated", %{payload: %{bot_id: ^id}}
  end
end
