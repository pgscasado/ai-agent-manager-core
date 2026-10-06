defmodule AgentManager.Prompts do
  @moduledoc """
  Prompt templates used by the answer pipeline, behind one interface so a
  deployment can bring its own wording without touching the pipeline:

      config :agent_manager, AgentManager.Prompts, impl: MyApp.Prompts

  The default is `AgentManager.Prompts.Default`. Whatever the wording, the
  answer JSON keeps the keys `AgentManager.Pipelines.Answer.Steps.ShapeAnswer`
  reads (`response`, `offer_human_attendance`, `missing_info`, ...).
  """

  @doc "Context text used when retrieval found nothing."
  @callback no_info() :: String.t()
  @doc "The main system prompt: rules + retrieved context + attendance instructions."
  @callback system(bot :: map(), context_text :: String.t()) :: String.t()
  @doc "Output-format instructions for the answer JSON."
  @callback json_format(
              languages :: [String.t()],
              has_attendance :: boolean(),
              direct_attendance :: boolean()
            ) :: String.t()
  @doc "Asks for `message` rewritten (in one of `languages`, when given)."
  @callback paraphrase(message :: String.t(), languages :: [String.t()]) :: String.t()
  @doc ~s(Classifies the user's reply to an offer of human attendance: "affirmative", "negative" or other.)
  @callback attendance_intent(last_message :: String.t(), text :: String.t()) :: String.t()
  @doc ~s(Whether a reply to "anything else?" was a refusal: "true", "false" or "undefined".)
  @callback inactivity_refusal(message :: String.t()) :: String.t()
  @doc "Picks the index (1-based, or -1) of the knowledge segment whose attachment fits the interaction."
  @callback choose_attachment(interaction :: String.t(), segments :: [map()]) :: String.t()

  def no_info, do: impl().no_info()
  def system(bot, context_text), do: impl().system(bot, context_text)

  def json_format(languages, has_attendance, direct_attendance),
    do: impl().json_format(languages, has_attendance, direct_attendance)

  def paraphrase(message, languages), do: impl().paraphrase(message, languages)
  def attendance_intent(last_message, text), do: impl().attendance_intent(last_message, text)
  def inactivity_refusal(message), do: impl().inactivity_refusal(message)

  def choose_attachment(interaction, segments),
    do: impl().choose_attachment(interaction, segments)

  defp impl,
    do: Application.get_env(:agent_manager, __MODULE__, [])[:impl] || AgentManager.Prompts.Default
end
