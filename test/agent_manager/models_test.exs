defmodule AgentManager.ModelsTest do
  use AgentManager.Case

  alias AgentManager.{Events, Models}
  alias AgentManager.Models.Adapters.{Anthropic, OpenAI}

  describe "resolve/2" do
    test "resolves provider:model specs, defaults and unknown providers" do
      assert {:ok, %{provider: "alt", name: "big", adapter: Fake}} = Models.resolve("alt:big")
      assert {:ok, %{spec: "fake:chat"}} = Models.resolve(nil)
      assert {:ok, %{spec: "fake:embed"}} = Models.resolve(nil, :embedding)
      assert {:ok, %{spec: "fake:bare"}} = Models.resolve("bare")
      assert {:error, {:unknown_provider, "nope"}} = Models.resolve("nope:x")
    end
  end

  test "chat publishes llm.completed with usage and a key hint, correlated to the caller" do
    Events.subscribe("llm.completed")

    Fake.set_responder(fn _messages, opts ->
      {:ok, "model=#{opts[:model]} key=#{opts[:api_key]}"}
    end)

    {:ok, response} =
      Models.chat("alt:m1", [%{role: :user, content: "hi"}],
        api_keys: %{"alt" => "sk-abcdefghijklmnop"},
        bot_id: "b1",
        correlation_id: "c1"
      )

    assert response.content == "model=m1 key=sk-abcdefghijklmnop"
    event = assert_event("llm.completed")
    assert event.bot_id == "b1" and event.correlation_id == "c1"
    assert event.payload.model == "alt:m1" and event.payload.key_hint == "sk-ab...lmnop"
    assert event.payload.usage.total_tokens >= 0
  end

  test "errors are returned and published as llm.failed" do
    Events.subscribe("llm.failed")
    Fake.set_responder(fn _, _ -> {:error, :rate_limited} end)
    assert {:error, :rate_limited} = Models.chat("fake:x", [%{role: :user, content: "hi"}])
    assert assert_event("llm.failed").payload.reason == ":rate_limited"
  end

  describe "OpenAI adapter" do
    test "sends an OpenAI chat request and parses the reply" do
      Req.Test.stub(:openai, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)
        assert conn.request_path == "/v1/chat/completions"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer k"]
        assert req["response_format"] == %{"type" => "json_object"}
        assert [%{"role" => "system"}, %{"role" => "user"}] = req["messages"]

        Req.Test.json(conn, %{
          "model" => req["model"],
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "{\"response\":\"ok\"}"}}
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3}
        })
      end)

      assert {:ok, %{content: ~s({"response":"ok"}), usage: %{total_tokens: 13}}} =
               OpenAI.chat([%{role: :system, content: "s"}, %{role: :user, content: "u"}],
                 model: "gpt-4o",
                 api_key: "k",
                 json: true,
                 req_options: [plug: {Req.Test, :openai}]
               )
    end

    test "embeddings keep input order" do
      Req.Test.stub(:openai_embed, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"index" => 1, "embedding" => [2.0]}, %{"index" => 0, "embedding" => [1.0]}]
        })
      end)

      assert {:ok, [[1.0], [2.0]]} =
               OpenAI.embed(["a", "b"],
                 model: "e",
                 req_options: [plug: {Req.Test, :openai_embed}]
               )
    end
  end

  describe "Anthropic adapter" do
    test "moves system prompts to the system field and sends no sampling params" do
      Req.Test.stub(:anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)
        assert conn.request_path == "/v1/messages"
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        assert req["system"] =~ "be nice"
        assert req["system"] =~ "single JSON object"
        assert [%{"role" => "user", "content" => "hi"}] = req["messages"]
        refute Map.has_key?(req, "temperature")

        Req.Test.json(conn, %{
          "model" => "claude-opus-5",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "{\"response\":\"olá\"}"}],
          "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
        })
      end)

      assert {:ok,
              %{
                content: ~s({"response":"olá"}),
                usage: %{prompt_tokens: 20, completion_tokens: 5}
              }} =
               Anthropic.chat(
                 [%{role: :system, content: "be nice"}, %{role: :user, content: "hi"}],
                 model: "claude-opus-5",
                 api_key: "k",
                 json: true,
                 temperature: 0.4,
                 req_options: [plug: {Req.Test, :anthropic}]
               )
    end

    test "refusals are errors" do
      Req.Test.stub(:anthropic_refusal, fn conn ->
        Req.Test.json(conn, %{
          "stop_reason" => "refusal",
          "stop_details" => %{"category" => "cyber"},
          "content" => []
        })
      end)

      assert {:error, {:refusal, %{"category" => "cyber"}}} =
               Anthropic.chat([%{role: :user, content: "x"}],
                 model: "m",
                 req_options: [plug: {Req.Test, :anthropic_refusal}]
               )
    end
  end
end
