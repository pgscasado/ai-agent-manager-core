defmodule AgentManagerWeb.CapsTest do
  @moduledoc "The hard caps and rate limits that keep a public deployment's spend bounded."
  use AgentManagerWeb.ConnCase

  alias AgentManager.{Budget, Models}
  alias AgentManager.Showcase.Settings
  alias AgentManager.WhatsApp.TestClient
  alias AgentManagerWeb.ClientIP

  setup do
    TestClient.clear()

    on_exit(fn ->
      Application.delete_env(:agent_manager, :api_token)
      Application.delete_env(:agent_manager, :trusted_proxies)
      Application.delete_env(:agent_manager, AgentManagerWeb.Plugs.RateLimit)
    end)

    :ok
  end

  defp hi, do: [%{role: :user, content: "hi"}]

  describe "provider keys" do
    test "a missing key fails before the call, naming the variable, without using budget" do
      original = Application.get_env(:agent_manager, AgentManager.Models)

      providers =
        Keyword.put(original[:providers], :keyed,
          adapter: AgentManager.Models.Adapters.Fake,
          api_key: {:system, "AM_TEST_NO_SUCH_KEY"}
        )

      Application.put_env(
        :agent_manager,
        AgentManager.Models,
        Keyword.put(original, :providers, providers)
      )

      Fake.set_responder(fn _, _ -> flunk("the provider must not be called without a key") end)

      try do
        assert {:error,
                {:missing_api_key, "set AM_TEST_NO_SUCH_KEY (or the bot's api_keys.keyed)"}} =
                 Models.chat("keyed:m", hi())

        assert Budget.usage()["model_calls"] == 0
        # a bot's own key is enough
        Fake.reset()
        assert {:ok, _} = Models.chat("keyed:m", hi(), api_keys: %{"keyed" => "bot-key"})
      after
        Application.put_env(:agent_manager, AgentManager.Models, original)
      end
    end
  end

  describe "model budget (the hard cap)" do
    test "refuses calls beyond the daily call budget" do
      {:ok, _} = Settings.update(%{"limits" => %{"model_calls_daily" => 2}})

      assert {:ok, _} = Models.chat("fake:chat", hi())
      assert {:ok, _} = Models.chat("fake:chat", hi())
      assert {:error, :daily_budget_exhausted} = Models.chat("fake:chat", hi())
      assert Budget.usage()["model_calls"] == 2
      assert Budget.exhausted?()
    end

    test "refuses calls once the daily token budget is spent" do
      {:ok, _} = Settings.update(%{"limits" => %{"model_tokens_daily" => 50}})
      long = [%{role: :user, content: String.duplicate("palavra ", 50)}]

      assert {:ok, _} = Models.chat("fake:chat", long)
      assert Budget.usage()["model_tokens"] >= 50
      assert {:error, :daily_budget_exhausted} = Models.chat("fake:chat", hi())
    end

    test "nil means unlimited" do
      {:ok, _} =
        Settings.update(%{"limits" => %{"model_calls_daily" => nil, "model_tokens_daily" => nil}})

      for _ <- 1..5, do: assert({:ok, _} = Models.chat("fake:chat", hi()))
      refute Budget.exhausted?()
    end

    test "covers the HTTP API too, not only WhatsApp", %{conn: conn} do
      bot =
        create_bot!()
        |> train!(%{"bot_name" => "Loja", "source_text" => "Entregamos em todo o Brasil."})

      {:ok, _} = Settings.update(%{"limits" => %{"model_calls_daily" => 0}})

      test_pid = self()

      Fake.set_responder(fn _, _ ->
        send(test_pid, :model_called) && {:ok, ~s({"response": "x"})}
      end)

      conn
      |> post("/message/#{bot.id}/get_answer", %{text: "oi", user_id: "u"})
      |> json_response(200)

      refute_received :model_called
    end
  end

  describe "per-IP rate limits" do
    test "API requests beyond the limit get 429 with Retry-After", %{conn: conn} do
      Application.put_env(:agent_manager, AgentManagerWeb.Plugs.RateLimit, api: {3, 60_000})

      for _ <- 1..3, do: assert(conn |> get("/models") |> json_response(200))
      limited = get(conn, "/models")
      assert json_response(limited, 429) == %{"error" => "rate limited"}
      assert [retry_after] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry_after) in 1..60
    end

    test "limits are per IP", %{conn: conn} do
      Application.put_env(:agent_manager, AgentManagerWeb.Plugs.RateLimit, api: {1, 60_000})

      assert conn |> get("/models") |> json_response(200)
      assert conn |> get("/models") |> json_response(429)

      other = %{conn | remote_ip: {10, 0, 0, 2}}
      assert other |> get("/models") |> json_response(200)
    end

    test "X-Forwarded-For is only believed from trusted proxies", %{conn: conn} do
      forwarded = put_req_header(conn, "x-forwarded-for", "6.6.6.6, 5.5.5.5")

      # not behind a trusted proxy: the header is ignored (anyone can send it)
      assert ClientIP.get(forwarded) == "127.0.0.1"

      Application.put_env(:agent_manager, :trusted_proxies, ["127.0.0.1"])
      # the right-most address not added by a trusted proxy is the client
      assert ClientIP.get(forwarded) == "5.5.5.5"

      spoofed = put_req_header(conn, "x-forwarded-for", "1.2.3.4, 127.0.0.1")
      assert ClientIP.get(spoofed) == "1.2.3.4"
      assert ClientIP.get(put_req_header(conn, "x-forwarded-for", "garbage")) == "127.0.0.1"
    end
  end

  describe "token brute force" do
    test "10 failures lock the IP out, even with the right token afterwards", %{conn: conn} do
      Application.put_env(:agent_manager, :api_token, "right")
      bad = put_req_header(conn, "authorization", "Bearer wrong")

      for _ <- 1..10, do: assert(bad |> get("/admin/showcase/usage") |> json_response(401))

      good = put_req_header(conn, "authorization", "Bearer right")
      assert good |> get("/admin/showcase/usage") |> json_response(429)
      # the socket shares the lockout
      assert :error = AgentManagerWeb.Plugs.ApiAuth.check("right", "127.0.0.1")

      # another IP is unaffected
      assert %{good | remote_ip: {10, 0, 0, 3}}
             |> get("/admin/showcase/usage")
             |> json_response(200)
    end
  end

  describe "WhatsApp floods" do
    defp webhook(conn, id) do
      body =
        Jason.encode!(%{
          "entry" => [
            %{
              "changes" => [
                %{
                  "value" => %{
                    "messages" => [
                      %{
                        "id" => id,
                        "from" => "5511777",
                        "type" => "text",
                        "text" => %{"body" => "oi"}
                      }
                    ]
                  }
                }
              ]
            }
          ]
        })

      sig =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, "test-app-secret", body) |> Base.encode16(case: :lower))

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sig)
      |> post("/whatsapp/webhook", body)
    end

    test "messages over the per-number rate are dropped (and Meta still gets 200)", %{conn: conn} do
      {:ok, _} = Settings.update(%{"limits" => %{"messages_per_minute" => 2}})

      for id <- ~w(w1 w2 w3 w4), do: assert(webhook(conn, id) |> response(200))

      # first message: welcome + menu; second: hint + menu; the rest dropped
      wait_until(fn -> length(TestClient.outbox("5511777")) >= 4 end)
      Process.sleep(100)
      assert length(TestClient.outbox("5511777")) == 4
    end
  end

  describe "uploads" do
    test "a zip that would expand past the limit is refused before unpacking" do
      {:ok, {_, zip}} =
        :zip.create(~c"bomb.zip", [{~c"word/document.xml", :binary.copy(<<0>>, 100_000)}], [
          :memory
        ])

      assert byte_size(zip) < 1_000
      assert {:error, :too_large} = AgentManager.Sources.Zip.unzip(zip, [], 10_000)
      assert {:ok, [_]} = AgentManager.Sources.Zip.unzip(zip, [], 1_000_000)
    end
  end
end
