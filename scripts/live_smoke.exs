# Live smoke test against real providers.
#
#   STORE=memory mix run scripts/live_smoke.exs
#
# Reads OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY (shell or .env) and
# tests every provider that has a key. Keys are never printed. Spends a few
# cents of tokens per provider. Override models with LIVE_OPENAI_MODEL,
# LIVE_ANTHROPIC_MODEL, LIVE_GEMINI_MODEL. LIVE_DRY_RUN=1 runs the same checks
# against the offline fake provider (no keys, no cost).

alias AgentManager.{Bots, Conversations, Events, Models, Tools, Training}

defmodule Live do
  def check(name, fun) do
    started = System.monotonic_time(:millisecond)

    {status, detail} =
      try do
        case fun.() do
          {:ok, detail} -> {:pass, detail}
          {:error, detail} -> {:fail, detail}
        end
      rescue
        e -> {:fail, Exception.message(e)}
      end

    ms = System.monotonic_time(:millisecond) - started
    mark = if status == :pass, do: "PASS", else: "FAIL"
    IO.puts("  [#{mark}] #{String.pad_trailing(name, 26)} #{ms}ms  #{truncate(detail)}")
    {name, status}
  end

  defp truncate(detail) do
    text = if is_binary(detail), do: detail, else: inspect(detail)
    text = String.replace(text, ~r/\s+/, " ")
    if String.length(text) > 160, do: String.slice(text, 0, 157) <> "...", else: text
  end

  def wait_for(type, bot_id, timeout) do
    receive do
      {:event, %{type: ^type, bot_id: ^bot_id} = event} -> {:ok, event}
      {:event, %{type: "training.failed", bot_id: ^bot_id} = event} -> {:error, event.payload.errors}
    after
      timeout -> {:error, :timeout}
    end
  end
end

dry_run? = System.get_env("LIVE_DRY_RUN") in ~w(1 true)

providers =
  if dry_run? do
    [{"fake (dry run)", nil, "fake:chat", "fake:embed"}]
  else
    [
      {"openai", "OPENAI_API_KEY", "openai:" <> System.get_env("LIVE_OPENAI_MODEL", "gpt-4o-mini"), "openai:text-embedding-3-small"},
      {"anthropic", "ANTHROPIC_API_KEY", "anthropic:" <> System.get_env("LIVE_ANTHROPIC_MODEL", "claude-opus-5"), nil},
      {"gemini", "GEMINI_API_KEY", "gemini:" <> System.get_env("LIVE_GEMINI_MODEL", "gemini-2.5-flash"), "gemini:gemini-embedding-001"}
    ]
    |> Enum.filter(fn {_, var, _, _} -> System.get_env(var) not in [nil, ""] end)
  end

if dry_run? do
  # Behave like a cooperative model so the dry run exercises every code path.
  AgentManager.Models.Adapters.Fake.set_responder(fn messages, opts ->
    tool_result = Enum.find(messages, &(&1.role == :tool))
    last_user = messages |> Enum.filter(&(&1.role == :user)) |> List.last()

    cond do
      opts[:tools] not in [nil, []] and is_nil(tool_result) ->
        {:ok, %{content: "", tool_calls: [%{id: "t1", name: "current_time", arguments: %{"utc_offset_hours" => -3}}]}}

      tool_result ->
        {:ok, Jason.encode!(%{response: "Agora são #{tool_result.content}."})}

      opts[:json] == true and last_user.content =~ "Bom dia" ->
        {:ok, ~s({"ok": true, "language": "pt"})}

      opts[:json] == true ->
        {:ok, Jason.encode!(%{response: "Resposta sobre: " <> last_user.content})}

      true ->
        {:ok, "pong"}
    end
  end)
end

if AgentManager.Store.impl() != AgentManager.Store.Memory do
  IO.puts("Run with STORE=memory so the test needs no database:  STORE=memory mix run scripts/live_smoke.exs")
  System.halt(1)
end

if providers == [] do
  IO.puts("""
  No provider keys found. Put one or more in .env (gitignored) or the shell:

      OPENAI_API_KEY=...
      ANTHROPIC_API_KEY=...
      GEMINI_API_KEY=...

  then run:  STORE=memory mix run scripts/live_smoke.exs
  """)

  System.halt(1)
end

IO.puts("Providers under test: #{Enum.map_join(providers, ", ", &elem(&1, 0))}\n")

time_tool = Enum.filter(Tools.available(), &(&1.id == "local:current_time"))

content = %{
  "bot_name" => "Loja Exemplo",
  "source_text" =>
    "A Loja Exemplo aceita pagamento em cartão de crédito, débito, pix e boleto bancário em todas as compras do site.\n\n" <>
      "Entregamos em até cinco dias úteis para todo o Brasil, com código de rastreio enviado por e-mail após o despacho.\n\n" <>
      "Trocas e devoluções podem ser solicitadas em até trinta dias corridos a partir do recebimento do pedido."
}

results =
  for {label, _var, chat_spec, embed_spec} <- providers do
    IO.puts("== #{label} (#{chat_spec})")

    checks = [
      Live.check("chat", fn ->
        with {:ok, r} <- Models.chat(chat_spec, [%{role: :user, content: "Reply with exactly the word: pong"}], max_tokens: 1_000) do
          if r.content =~ ~r/pong/i, do: {:ok, "#{inspect(r.content)} usage=#{r.usage.total_tokens}"}, else: {:error, r.content}
        end
      end),
      Live.check("json mode", fn ->
        messages = [
          %{role: :system, content: ~s(Answer as a JSON object: {"ok": true, "language": "<ISO 639-1 code of the user's message>"})},
          %{role: :user, content: "Bom dia, tudo bem?"}
        ]

        with {:ok, r} <- Models.chat(chat_spec, messages, json: true, max_tokens: 1_000),
             {:ok, map} <- AgentManager.JSON.decode_object(r.content) do
          if map["language"] in ["pt", "pt-BR"], do: {:ok, inspect(map)}, else: {:error, inspect(map)}
        end
      end),
      Live.check("native tool call", fn ->
        messages = [%{role: :user, content: "What is the current UTC time? Use the available tool."}]

        with {:ok, r} <- Models.chat(chat_spec, messages, tools: Tools.definitions(time_tool), max_tokens: 1_000) do
          case r.tool_calls do
            [%{name: "current_time"} = call | _] -> {:ok, "called current_time #{inspect(call.arguments)}"}
            _ -> {:error, "no tool call; said: #{r.content}"}
          end
        end
      end),
      if(embed_spec,
        do:
          Live.check("embeddings", fn ->
            with {:ok, [v1, v2]} <- Models.embed(embed_spec, ["pagamento com pix", "formas de pagamento"]) do
              {:ok, "dims=#{length(v1)} cosine=#{Float.round(AgentManager.NLP.Text.cosine(v1, v2), 3)}"}
            end
          end),
        else: {"embeddings", :skipped}
      ),
      Live.check("train + answer from knowledge", fn ->
        {:ok, bot} =
          Bots.create(%{
            "name" => "live-#{label}",
            "model_config" => %{"llm_model" => chat_spec, "embedding_model" => embed_spec || "fake:embed", "tools" => ["local:*"]}
          })

        Events.subscribe({:bot, bot.id})
        {:ok, _} = Training.request(bot, content)

        with {:ok, done} <- Live.wait_for("training.completed", bot.id, 120_000) do
          Process.put(:live_bot, bot.id)
          bot = Bots.get(bot.id)
          {:ok, answer, ctx} = Conversations.ask(bot, "live-user", "Quais formas de pagamento vocês aceitam?")

          if answer.error,
            do: {:error, "handoff: #{answer.response}"},
            else: {:ok, "#{done.payload.stats.new_segments} segments; answer=#{inspect(answer.response)} tokens=#{ctx.usage.total_tokens}"}
        end
      end),
      Live.check("answer using a tool", fn ->
        case Process.get(:live_bot) do
          nil ->
            {:error, "skipped: training failed"}

          bot_id ->
            bot = Bots.get(bot_id)
            {:ok, answer, _ctx} = Conversations.ask(bot, "live-user", "Que horas são agora em Brasília (UTC-3)? Use a ferramenta de horário.")

            cond do
              answer.error -> {:error, "handoff: #{answer.response}"}
              "local:current_time" in (answer.metadata[:tools_used] || []) -> {:ok, "tools_used=#{inspect(answer.metadata.tools_used)} answer=#{inspect(answer.response)}"}
              true -> {:error, "model answered without the tool: #{answer.response}"}
            end
        end
      end)
    ]

    IO.puts("")
    {label, checks}
  end

failed = for {label, checks} <- results, {name, :fail} <- checks, do: "#{label}/#{name}"

if failed == [] do
  IO.puts("All checks passed.")
else
  IO.puts("Failed: #{Enum.join(failed, ", ")}")
  System.halt(1)
end
