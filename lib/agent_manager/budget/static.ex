defmodule AgentManager.Budget.Static do
  @moduledoc """
  The default source of `AgentManager.Budget` limits: plain config, set from
  environment variables in `config/runtime.exs` (`MODEL_CALLS_DAILY`,
  `MODEL_TOKENS_DAILY`, `QA_CALLS_DAILY`, `QA_TOKENS_DAILY`):

      config :agent_manager, AgentManager.Budget,
        daily: %{"model_calls_daily" => 1_000, "model_tokens_daily" => 2_000_000}

  A missing limit is unlimited. Days are UTC days.
  """
  @behaviour AgentManager.Budget

  @impl true
  def limit(name),
    do: (Application.get_env(:agent_manager, AgentManager.Budget, [])[:daily] || %{})[name]

  @impl true
  def today, do: Date.utc_today()
end
