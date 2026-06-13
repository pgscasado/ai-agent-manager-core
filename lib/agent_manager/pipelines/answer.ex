defmodule AgentManager.Pipelines.Answer do
  @moduledoc """
  Turns a user message into an `AgentManager.Answer`.

  Input: `%{text: String.t(), user_id: String.t(), history: [Message.t()]}`
  plus `bot:` in the run opts. Output: `ctx.result` is an `%Answer{}`.

      RunCommands -> CheckDisabled -> PrepareHistory -> StartMessage
        -> (DetectLanguage || RetrieveContext)       # concurrently
        -> InactivityFollowUp -> AttendanceConfirmation
        -> BuildPrompt -> Generate -> ResolveAttachments -> ShapeAnswer

  Each step is a module in `AgentManager.Pipelines.Answer.Steps`; see
  `AgentManager.Pipeline` for inserting, replacing or removing them.
  """

  use AgentManager.Pipeline

  alias AgentManager.Pipelines.Answer.Steps

  step(Steps.RunCommands)
  step(Steps.CheckDisabled)
  step(Steps.PrepareHistory)
  step(Steps.StartMessage)

  parallel([Steps.DetectLanguage, {Steps.RetrieveContext, k: 100, min_segments: 5}],
    name: :enrich
  )

  step(Steps.InactivityFollowUp, when: :asked_if_more_help)
  step(Steps.AttendanceConfirmation, when: :offered_attendance)
  step(Steps.BuildPrompt)
  step(Steps.Generate, retry: 1, timeout: 90_000, on_error: {:recover, &Steps.Generate.recover/2})
  step(Steps.ResolveAttachments, on_error: :continue)
  step(Steps.ShapeAnswer)
end
