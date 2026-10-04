defmodule AgentManager.ConversationsTest do
  use AgentManager.Case

  alias AgentManager.{Bots, Conversations, Events, Store}
  alias AgentManager.Pipelines.Answer

  @content %{
    "bot_name" => "Loja",
    "source_text" =>
      "Aceitamos pagamento em cartão de crédito, débito e pix em todas as compras.\n\nA entrega é feita em até cinco dias úteis para todo o Brasil."
  }

  setup do
    {:ok, bot: create_bot!() |> train!(@content)}
  end

  test "answers with retrieved context and persists the exchange via events", %{bot: bot} do
    test_pid = self()

    Fake.set_responder(fn messages, opts ->
      if opts[:json], do: send(test_pid, {:prompt, messages})

      {:ok,
       ~s({"response": "Aceitamos pix.", "offer_human_attendance": "false", "is_greeting_response": "false"})}
    end)

    Events.subscribe({:bot, bot.id})
    assert {:ok, answer, ctx} = Conversations.ask(bot, "u1", "Vocês aceitam pix?")
    assert answer.response == "Aceitamos pix."
    assert ctx.usage.total_tokens > 0

    assert_receive {:prompt, [system, format, user]}
    assert system.content =~ "pagamento em cartão"
    assert format.content =~ "JSON"
    assert user.content == "Vocês aceitam pix?"

    assert_event("message.received")
    assert_event("llm.completed")
    assert_event("message.answered")
    wait_until(fn -> length(Store.impl().list_messages(bot.id, "u1", [])) == 1 end)
    wait_until(fn -> Bots.get(bot.id).total_tokens > 0 end)
  end

  test "history from earlier turns is sent to the model", %{bot: bot} do
    test_pid = self()

    Fake.set_responder(fn messages, opts ->
      if opts[:json], do: send(test_pid, {:prompt, messages})
      {:ok, ~s({"response": "ok"})}
    end)

    {:ok, _, _} = Conversations.ask(bot, "u1", "primeira pergunta")
    assert_receive {:prompt, _}
    {:ok, _, _} = Conversations.ask(bot, "u1", "segunda pergunta")
    assert_receive {:prompt, messages}

    assert [:system, :system, :user, :assistant, :user] = Enum.map(messages, & &1.role)
    assert Enum.at(messages, 2).content == "primeira pergunta"
  end

  test "each user gets an isolated, supervised conversation process", %{bot: bot} do
    {:ok, _, _} = Conversations.ask(bot, "a", "oi")
    {:ok, _, _} = Conversations.ask(bot, "b", "oi")
    pid_a = Conversations.whereis(bot.id, "a")
    assert pid_a != Conversations.whereis(bot.id, "b")

    Process.exit(pid_a, :kill)
    assert {:ok, _, _} = Conversations.ask(bot, "a", "ainda aí?")
    assert Conversations.whereis(bot.id, "a") != pid_a
  end

  test "one user's messages never overlap; different users run concurrently", %{bot: bot} do
    # Tracks how many answer generations are in flight at once.
    {:ok, gauge} = Agent.start_link(fn -> {0, 0} end)

    Fake.set_responder(fn _messages, opts ->
      if opts[:json] do
        Agent.update(gauge, fn {now, peak} -> {now + 1, max(peak, now + 1)} end)
        Process.sleep(40)
        Agent.update(gauge, fn {now, peak} -> {now - 1, peak} end)
      end

      {:ok, ~s({"response": "ok"})}
    end)

    ask_all = fn users ->
      users
      |> Enum.with_index(1)
      |> Enum.map(fn {user, n} ->
        Task.async(fn -> Conversations.ask(bot, user, "msg #{n}") end)
      end)
      |> Enum.each(&Task.await/1)
    end

    Events.subscribe("message.answered")
    ask_all.(List.duplicate("same", 5))
    assert {0, 1} = Agent.get(gauge, & &1)

    # Stored in the order they were answered.
    answered = for _ <- 1..5, do: assert_event("message.answered").payload.text
    wait_until(fn -> length(Store.impl().list_messages(bot.id, "same", [])) == 5 end)
    assert Enum.map(Store.impl().list_messages(bot.id, "same", []), & &1.message) == answered

    Agent.update(gauge, fn _ -> {0, 0} end)
    ask_all.(for n <- 1..5, do: "user-#{n}")
    assert {0, peak} = Agent.get(gauge, & &1)
    assert peak > 1
  end

  test "start message on first contact, then the model", %{bot: bot} do
    {:ok, bot} = Bots.update(bot, %{"start_message" => "Bem-vindo!"})
    assert {:ok, %{response: "Bem-vindo!"}, _} = Conversations.ask(bot, "new", "oi")
    wait_until(fn -> Store.impl().list_messages(bot.id, "new", []) != [] end)
    assert {:ok, %{response: "Echo: " <> _}, _} = Conversations.ask(bot, "new", "oi de novo")
  end

  test "a disabled bot hands off to attendance", %{bot: bot} do
    {:ok, bot} = Bots.update(bot, %{"disabled" => true})
    assert {:ok, answer, _} = Conversations.ask(bot, "u", "oi")
    assert answer.start_attendance and answer.metadata.is_bot_disabled
  end

  test "+limpar historico clears stored and in-memory history", %{bot: bot} do
    {:ok, _, _} = Conversations.ask(bot, "u", "oi")
    wait_until(fn -> Store.impl().list_messages(bot.id, "u", []) != [] end)

    assert {:ok, %{response: "Limpei o histórico de mensagens!"}, _} =
             Conversations.ask(bot, "u", "+limpar historico")

    assert Store.impl().list_messages(bot.id, "u", []) == []

    test_pid = self()

    Fake.set_responder(fn messages, opts ->
      if opts[:json], do: send(test_pid, {:roles, Enum.map(messages, & &1.role)})
      {:ok, ~s({"response": "ok"})}
    end)

    {:ok, _, _} = Conversations.ask(bot, "u", "e agora?")
    assert_receive {:roles, [:system, :system, :user]}
  end

  test "an attendance offer followed by 'yes' hands off to a human", %{bot: bot} do
    Fake.set_responder(fn messages, opts ->
      prompt = messages |> List.last() |> Map.get(:content)

      cond do
        prompt =~ "Is User's message" ->
          {:ok, ~s({"response": "affirmative"})}

        prompt =~ "Rewrite <" ->
          {:ok, prompt |> String.split(["<", ">"]) |> Enum.at(1)}

        prompt =~ "Rate the sentiment" ->
          {:ok, "5"}

        opts[:json] ->
          {:ok,
           ~s({"response": "Isso é com um atendente. Deseja falar com um atendente?", "offer_human_attendance": "true", "is_greeting_response": "false"})}

        true ->
          {:ok, "x"}
      end
    end)

    {:ok, first, _} = Conversations.ask(bot, "u", "quero cancelar meu pedido")
    assert first.asked_for_attendance
    wait_until(fn -> Store.impl().list_messages(bot.id, "u", []) != [] end)

    {:ok, second, _} = Conversations.ask(bot, "u", "sim, por favor")
    assert second.start_attendance
    assert second.metadata.is_end_of_conversation
    assert second.response =~ "consultor"
  end

  test "line breaks escaped twice, the ANEXO placeholder and a stray brace are cleaned", %{
    bot: bot
  } do
    # in the JSON: "\\n" decodes to a backslash and an "n", which WhatsApp shows as is
    Fake.set_responder(fn _messages, _opts ->
      {:ok,
       ~S|{"response": "Temos duas camisetas.\\n\\nQual você quer?\\n\\n\\n} ANEXO(<LINK>)"}|}
    end)

    assert {:ok, %{response: "Temos duas camisetas.\n\nQual você quer?"}, _ctx} =
             Conversations.ask(bot, "u", "camisetas?")
  end

  test "the 1.0 line-break and attachment markers are only for bots that use them", %{bot: bot} do
    {:ok, messages, _} = Conversations.preview_prompt(bot, "u", "oi")
    [%{content: system} | _] = messages
    refute system =~ ~s(Never omit "\\n")
    refute system =~ "ANEXO("

    {:ok, bot} =
      Bots.update(bot, %{
        "model_config" => %{
          "content" => %{
            "behavioral_rules" => ~S|Separe parágrafos com "\n". Envie ANEXO(https://x.pdf).|
          }
        }
      })

    {:ok, [%{content: system} | _], _} = Conversations.preview_prompt(bot, "u2", "oi")
    assert system =~ ~s(Never omit "\\n")
    assert system =~ ~s(Never omit "ANEXO)
  end

  test "model failures produce the technical-problem handoff", %{bot: bot} do
    Fake.set_responder(fn _messages, opts ->
      if opts[:json], do: {:error, :down}, else: {:ok, "Problema técnico."}
    end)

    assert {:ok, answer, ctx} = Conversations.ask(bot, "u", "oi?")
    assert answer.error and answer.start_attendance

    assert {Answer.Steps.Generate, :error, _} =
             Enum.find(ctx.trace, &(elem(&1, 0) == Answer.Steps.Generate))
  end

  test "swapping the bot's model is a config change", %{bot: bot} do
    test_pid = self()

    Fake.set_responder(fn _messages, opts ->
      send(test_pid, {:model, opts[:model]})
      {:ok, ~s({"response": "ok"})}
    end)

    {:ok, _, _} = Conversations.ask(bot, "u", "oi")
    assert_receive {:model, "chat"}

    {:ok, bot} = Bots.patch_model_field(bot, :llm_model, "alt:bigger")
    {:ok, _, _} = Conversations.ask(bot, "u", "oi")
    assert_receive {:model, "bigger"}
  end

  test "inactivity timers publish events", %{bot: bot} do
    {:ok, bot} = Bots.set_job_timings(bot, 1, 2)
    Events.subscribe("conversation.inactive")
    Events.subscribe("conversation.nps_due")

    {:ok, _, _} = Conversations.ask(bot, "idle", "oi")
    assert assert_event("conversation.inactive", 500).payload.user_id == "idle"
    assert assert_event("conversation.nps_due", 500).payload.minutes == 2
  end
end
