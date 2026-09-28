# Live demo of what happens inside: creates and trains a bot, asks it a few
# questions and switches its model mid-conversation, printing the events as
# they are published on the bus.
#
#   STORE=memory mix run scripts/demo_events.exs
#
# Uses local models through Ollama by default; override with DEMO_CHAT_MODEL,
# DEMO_SWAP_MODEL and DEMO_EMBEDDING_MODEL (any "provider:model" spec).

Logger.configure(level: :error)

alias AgentManager.{Bots, Conversations, Events, Training}

chat_model = System.get_env("DEMO_CHAT_MODEL", "ollama:qwen2.5:3b")
swap_model = System.get_env("DEMO_SWAP_MODEL", "ollama:qwen2.5:1.5b")
embedding_model = System.get_env("DEMO_EMBEDDING_MODEL", "ollama:embeddinggemma")

defmodule Demo do
  @reset "\e[0m"
  @dim "\e[2m"
  @bold "\e[1m"
  @violet "\e[38;5;141m"
  @green "\e[38;5;114m"
  @yellow "\e[38;5;221m"
  @blue "\e[38;5;75m"
  @pink "\e[38;5;211m"

  @step_names %{
    "RunCommands" => "commands",
    "CheckDisabled" => "disabled?",
    "PrepareHistory" => "history",
    "StartMessage" => "start",
    "DetectLanguage" => "language",
    "RetrieveContext" => "retrieval",
    "InactivityFollowUp" => "inactivity",
    "AttendanceConfirmation" => "attendance",
    "BuildPrompt" => "prompt",
    "Generate" => "generate",
    "ResolveAttachments" => "attachments",
    "ShapeAnswer" => "shape",
    "ValidateRules" => "rules",
    "InferStructure" => "structure",
    "FetchSources" => "sources",
    "Segment" => "segment",
    "Diff" => "diff",
    "Embed" => "embed",
    "Index" => "index",
    "Finalize" => "finalize"
  }

  def title(text), do: IO.puts("\n#{@bold}#{@violet}▸ #{text}#{@reset}")
  def user(name, text), do: IO.puts("\n#{@bold}#{name}:#{@reset} #{text}")

  def event(type, detail),
    do: IO.puts("  #{@blue}#{String.pad_trailing(type, 19)}#{@reset}#{detail}")

  def answer(text) do
    lines = wrap(text, 72)
    IO.puts("#{@bold}#{@green}bot:#{@reset} #{@green}#{hd(lines)}#{@reset}")
    for line <- tl(lines), do: IO.puts("     #{@green}#{line}#{@reset}")
  end

  def dim(text), do: "#{@dim}#{text}#{@reset}"
  def yellow(text), do: "#{@yellow}#{text}#{@reset}"
  def pink(text), do: "#{@pink}#{text}#{@reset}"

  def bar(percent) do
    filled = round(percent / 10)

    yellow(String.duplicate("█", filled)) <>
      dim(String.duplicate("░", 10 - filled)) <> " #{round(percent)}%"
  end

  def ms(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 1)}s"
  def ms(us), do: "#{div(us, 1000)}ms"

  def step_name(step) do
    short = step |> inspect() |> String.split(".") |> List.last()
    Map.get(@step_names, short, short)
  end

  # Runs `fun` in a task and prints bus events until it finishes. The pipeline
  # steps are drawn on a single line that grows as each step completes.
  def live(fun) do
    parent = self()
    Task.start(fn -> send(parent, {:done, fun.()}) end)
    loop([])
  end

  defp loop(steps) do
    receive do
      {:done, result} ->
        if steps != [], do: IO.write("\n")
        result

      {:event, %{type: "pipeline.step.completed", payload: p}} ->
        label = step_name(p.step)

        label =
          if p.duration_us > 50_000, do: "#{label} #{yellow(ms(p.duration_us))}", else: label

        steps = steps ++ [label]

        IO.write(
          "\r\e[2K  #{"\e[38;5;75m"}#{String.pad_trailing("pipeline", 19)}#{@reset}#{Enum.join(steps, dim(" › "))}"
        )

        loop(steps)

      {:event, %{type: type} = e} ->
        line = format(type, e.payload)

        if line do
          if steps != [], do: IO.write("\n")
          event(type, line)
          loop([])
        else
          loop(steps)
        end
    end
  end

  defp format("training.progress", p), do: "#{bar(p.percent)} #{dim(to_string(p.stage))}"

  defp format("training.completed", p),
    do: "#{p.stats.new_segments} segments indexed in #{ms(p.duration_ms * 1000)}"

  defp format("llm.completed", p),
    do:
      "#{pink(p.model)} #{dim("·")} #{p.usage.total_tokens} tokens #{dim("·")} #{ms(p.latency_ms * 1000)}"

  defp format("tool.called", p), do: "#{pink(p.tool)} #{dim(Jason.encode!(p.arguments))}"
  defp format("tool.completed", p), do: "#{p.id} #{dim("·")} #{p.duration_ms}ms"
  defp format("message.received", _p), do: dim("→ conversation process")
  defp format(_type, _payload), do: nil

  defp wrap(text, width) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([""], fn word, [line | rest] ->
      cond do
        line == "" -> [word | rest]
        String.length(line) + 1 + String.length(word) > width -> [word, line | rest]
        true -> [line <> " " <> word | rest]
      end
    end)
    |> Enum.reverse()
  end
end

content = %{
  "bot_name" => "Lia",
  "behavioral_rules" =>
    "Você é a Lia, atendente virtual da Loja Demo. Responda em uma ou duas frases, de forma simpática, apenas com base nas informações fornecidas. [pt]",
  "source_text" =>
    "Formas de pagamento: aceitamos cartão de crédito em até 6x sem juros, cartão de débito, pix com 5% de desconto e boleto bancário.\n\n" <>
      "Entregas: enviamos para todo o Brasil em até cinco dias úteis. O frete é grátis em compras acima de R$ 200.\n\n" <>
      "Trocas e devoluções: podem ser pedidas em até trinta dias corridos após o recebimento, com a etiqueta presa ao produto."
}

IO.puts("\e[1mai-agent-manager\e[0m \e[2m· event bus, live\e[0m")

{:ok, bot} =
  Bots.create(%{
    "identifier" => "loja-demo",
    "model_config" => %{
      "llm_model" => chat_model,
      "embedding_model" => embedding_model,
      "tools" => ["local:current_time"]
    }
  })

Events.subscribe({:bot, bot.id})

Demo.title("training #{Demo.pink(embedding_model)}")
Demo.live(fn -> {:ok, _} = Training.request(bot, content) end)

# wait for training to finish, printing its events
Demo.live(fn ->
  Stream.repeatedly(fn -> Process.sleep(100) && Bots.get(bot.id).training_info.status end)
  |> Enum.find(&(&1 in [:FINISHED, :ERROR]))
end)

ask = fn bot, text ->
  Demo.user("maria", text)
  {:ok, answer, _ctx} = Demo.live(fn -> Conversations.ask(bot, "maria", text) end)
  Demo.answer(answer.response)
end

bot = Bots.get(bot.id)
ask.(bot, "Vocês aceitam pix?")
ask.(bot, "Que horas são agora em Brasília?")

Demo.title("PATCH /bot/loja-demo/models  llm_model → #{Demo.pink(swap_model)}")
{:ok, bot} = Bots.patch_model_field(bot, :llm_model, swap_model)
ask.(bot, "E se eu comprar 250 reais, o frete é grátis?")

IO.puts("")
