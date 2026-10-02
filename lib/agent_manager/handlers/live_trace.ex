defmodule AgentManager.Handlers.LiveTrace do
  @moduledoc """
  Prints what happens inside, live, on the server's console: WhatsApp messages
  in and out (and Meta's error when a send fails), showcase state changes,
  each answer's pipeline steps with their timings, model calls with tokens,
  tool calls with arguments and results, and training.

      LIVE_TRACE=true mix phx.server

  Steps are collected per run (correlation id) and printed as one line when
  the answer is ready, so concurrent conversations don't interleave mid-line.
  """
  use AgentManager.Events.Handler, subscribe: [:all]

  alias AgentManager.Bots

  @reset "\e[0m"
  @dim "\e[2m"
  @bold "\e[1m"
  @red "\e[38;5;203m"
  @green "\e[38;5;114m"
  @yellow "\e[38;5;221m"
  @blue "\e[38;5;75m"
  @pink "\e[38;5;211m"
  @violet "\e[38;5;141m"

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
    "ShapeAnswer" => "shape"
  }

  def enabled?, do: Application.get_env(:agent_manager, __MODULE__, [])[:enabled] == true

  @impl true
  def init_state(_opts), do: %{steps: %{}, bots: %{}}

  @impl true
  def handle_event(event, state) do
    {lines, state} = format(event, state)
    Enum.each(lines, &IO.puts/1)
    {:ok, state}
  end

  @doc "Lines to print for `event` (pure, apart from looking up bot names)."
  def format(%{type: "pipeline.step.completed", correlation_id: cid, payload: p}, state) do
    label = step_name(p.step)
    label = if p.duration_us > 50_000, do: "#{label} #{yellow(ms(p.duration_us))}", else: label
    label = if p.status in [:error, "error"], do: red(label <> " ✗"), else: label
    {[], %{state | steps: Map.update(state.steps, cid, [label], &[label | &1])}}
  end

  def format(%{type: "message.answered", correlation_id: cid, payload: p} = e, state) do
    {steps, state} = pop_steps(state, cid)
    {bot, state} = bot_name(state, e.bot_id)
    usage = p[:usage] || %{}

    lines =
      Enum.reject(
        [
          steps && line("pipeline", "#{dim(bot)} " <> Enum.join(steps, dim(" › "))),
          line(
            "answer",
            green(clip(p.answer["response"], 300)) <>
              dim(" · #{usage[:prompt_tokens] || 0} in / #{usage[:completion_tokens] || 0} out")
          )
        ],
        &is_nil/1
      )

    {lines, state}
  end

  def format(%{type: type} = e, state) do
    {bot, state} = bot_name(state, e.bot_id)

    # training runs end here (and runs that failed never reach message.answered)
    {steps, state} =
      if type in ["training.completed", "training.failed"],
        do: pop_steps(state, e.correlation_id),
        else: {nil, trim_steps(state)}

    lines =
      [
        steps && line("pipeline", "#{dim(bot)} " <> Enum.join(steps, dim(" › "))),
        describe(type, e.payload, bot)
      ]
      |> Enum.reject(&is_nil/1)

    {lines, state}
  end

  # -- one-liners ----------------------------------------------------------------

  defp describe("channel.received", p, _bot) do
    what =
      case p.type do
        :text -> p.text
        :reply -> "#{dim("tap")} #{p.reply_id}"
        :document -> "#{dim("file")} #{p.filename}"
        other -> dim(to_string(other))
      end

    "\n#{time()} #{@bold}#{@violet}📥 #{who(p.channel, p.from)}#{@reset}" <>
      dim("#{if p.name, do: " (#{p.name})"} [#{p.state}]") <> " #{clip(what, 300)}"
  end

  defp describe("channel.sent", p, _bot),
    do: "#{time()} #{@blue}📤 #{who(p.channel, p.to)}#{@reset} #{p.summary}"

  defp describe("channel.send_failed", p, _bot),
    do:
      "#{time()} #{red("📤✗ #{who(p.channel, p.to)} #{p.summary}")}\n         #{red(clip(p.reason, 500))}"

  defp describe("showcase.state", p, _bot),
    do:
      line(
        "state",
        "#{p.from_state} → #{@bold}#{p.to_state}#{@reset}#{if p.bot, do: dim(" (#{p.bot})")}"
      )

  defp describe("llm.completed", p, _bot) do
    u = p.usage

    line(
      "model",
      "#{pink(p.model)} #{dim("·")} #{u[:prompt_tokens] || 0} in / #{u[:completion_tokens] || 0} out #{dim("·")} #{ms(p.latency_ms * 1000)}"
    )
  end

  defp describe("llm.failed", p, _bot),
    do: line("model", red("#{p.model} failed after #{p.latency_ms}ms: #{clip(p.reason, 400)}"))

  defp describe("tool.called", p, _bot),
    do: line("tool", "#{pink(p.tool)} #{dim(Jason.encode!(p.arguments))}")

  defp describe("tool.completed", p, _bot) do
    mark = if p.is_error, do: red("✗"), else: green("✓")

    line(
      "tool",
      "#{mark} #{p.tool} #{dim("#{p.duration_ms}ms →")} #{clip(p[:result] || "", 300)}"
    )
  end

  defp describe("training.started", _p, bot), do: line("training", "#{bot} started")

  defp describe("training.completed", p, bot),
    do:
      line(
        "training",
        green("#{bot} ready") <>
          dim(" · #{p.stats.new_segments} segments · #{ms(p.duration_ms * 1000)}")
      )

  defp describe("training.failed", p, bot),
    do: line("training", red("#{bot} failed: #{inspect(p.errors)}"))

  defp describe(_type, _payload, _bot), do: nil

  # -- helpers ---------------------------------------------------------------------

  defp pop_steps(state, cid) do
    case Map.pop(state.steps, cid) do
      {nil, steps} -> {nil, %{state | steps: steps}}
      {labels, steps} -> {Enum.reverse(labels), %{state | steps: steps}}
    end
  end

  defp trim_steps(%{steps: steps} = state) when map_size(steps) > 100, do: %{state | steps: %{}}
  defp trim_steps(state), do: state

  defp bot_name(state, nil), do: {nil, state}

  defp bot_name(state, bot_id) do
    case state.bots do
      %{^bot_id => name} ->
        {name, state}

      bots ->
        name = (Bots.get(bot_id) || %{identifier: String.slice(bot_id, 0, 8)}).identifier
        {name, %{state | bots: Map.put(bots, bot_id, name)}}
    end
  end

  # WhatsApp numbers as they are; other channels prefixed (http:alice)
  defp who("whatsapp", address), do: address
  defp who(channel, address), do: "#{channel}:#{address}"

  defp line(label, text), do: "         #{@blue}#{String.pad_trailing(label, 9)}#{@reset}#{text}"

  defp step_name(step) do
    short = step |> inspect() |> String.split(".") |> List.last()
    Map.get(@step_names, short, short)
  end

  defp time, do: dim(Time.utc_now() |> Time.truncate(:second) |> Time.to_iso8601())

  defp ms(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 1)}s"
  defp ms(us), do: "#{div(us, 1000)}ms"

  defp clip(nil, _), do: ""

  defp clip(text, max) do
    text = text |> to_string() |> String.replace(~r/\s+/, " ")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp dim(text), do: "#{@dim}#{text}#{@reset}"
  defp red(text), do: "#{@red}#{text}#{@reset}"
  defp green(text), do: "#{@green}#{text}#{@reset}"
  defp yellow(text), do: "#{@yellow}#{text}#{@reset}"
  defp pink(text), do: "#{@pink}#{text}#{@reset}"
end
