defmodule AgentManager.Prompts.Default do
  @moduledoc """
  Generic prompts: enough for a support bot that answers from its knowledge,
  in the answer JSON the pipeline expects. Deployments tune their own wording
  through `AgentManager.Prompts`.
  """
  @behaviour AgentManager.Prompts

  @default_rules """
  You are "{botName}", a support assistant. Answer only from the information below. \
  If the answer isn't there, say you don't know. Don't answer questions about anything else.
  """

  @impl true
  def no_info, do: "No information available."

  @impl true
  def system(bot, context_text) do
    content = bot.model_config.content

    rules =
      if blank?(content.behavioral_rules), do: @default_rules, else: content.behavioral_rules

    rules = String.replace(rules, "{botName}", content.bot_name || bot.name || "")

    legacy(rules, context_text) <>
      rules <> "\nInformation:\n" <> context_text <> "\n" <> attendance(bot)
  end

  # Markers of the 1.0 platform, only for bots whose rules or knowledge use
  # them: line breaks written as "\n" and attachments as ANEXO(<link>).
  defp legacy(rules, context_text) do
    if(String.contains?(rules, "\\n"),
      do: ~s(Keep every "\\n" of your instructions in your answer, as written.\n),
      else: ""
    ) <>
      if String.contains?(rules <> context_text, "ANEXO("),
        do:
          "Keep every ANEXO(<link>) you are told to send, exactly as written; never add one yourself.\n",
        else: ""
  end

  defp attendance(%{has_attendance: false}), do: ""

  defp attendance(_bot) do
    """
    ___
    Set "offer_human_attendance" to "true" when the user should talk to a human attendant, \
    and end your answer asking whether they want to; otherwise set it to "false".
    """
  end

  @impl true
  def json_format(languages, has_attendance, direct_attendance) do
    language =
      case languages do
        [] -> ""
        langs -> " in " <> Enum.join(langs, " or ") <> ", the language of the question"
      end

    attendance = if has_attendance, do: ~s("true" or "false"), else: ~s("false")

    redirect =
      if direct_attendance,
        do: "",
        else: ~s("redirect_to_assistant_message": "<a way to ask if they want an attendant>", )

    ~s(Answer with JSON only: { "response": "<your answer#{language}>", "offer_human_attendance": #{attendance}, #{redirect}"missing_info": "true" or "false" \(the information didn't answer it\), "yes_or_no_question": "true" or "false" \(your answer asks a yes/no question\), "response_language": "<ISO 639-1 code>", "is_greeting_response": "true" or "false" })
  end

  @impl true
  def paraphrase(message, []),
    do: "Rewrite <#{message}>. Reply with the rewritten text only."

  def paraphrase(message, languages),
    do:
      "Rewrite <#{message}> in one of #{Enum.join(languages, ", ")}, the language it was written in. Reply with the rewritten text only."

  @impl true
  def attendance_intent(last_message, text) do
    ~s(Assistant: "#{last_message}" -> User: "#{text}". Is the user's reply "affirmative", "negative" or "unrelated"? Answer in JSON with the key "response".)
  end

  @impl true
  def inactivity_refusal(message) do
    ~s(A user was asked whether they need anything else and replied: #{message}\nWas that a no? Answer with one word: "true" if it was, "false" if it wasn't, "undefined" if unrelated.)
  end

  @impl true
  def choose_attachment(interaction, segments) do
    list =
      segments
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {seg, i} ->
        "#{i}: #{AgentManager.Attachments.mask(seg.segment)}"
      end)

    ~s(Interaction: #{interaction}\nItems, each with an attachment:\n#{list}\nWhich item fits the interaction best? Reply with its number only, or -1 if none does.)
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""
end
