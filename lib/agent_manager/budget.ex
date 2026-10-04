defmodule AgentManager.Budget do
  @moduledoc """
  The hard cap on model spend: a daily budget of chat-model calls and tokens
  that every call goes through (`Models.chat/3`), whatever started it - the
  WhatsApp showcase, the HTTP API, tool rounds, a future route or a bug.

  Limits come from the runtime settings (`limits.model_calls_daily`,
  `limits.model_tokens_daily`; `nil` is unlimited), so they change without a
  deploy. Calls are reserved atomically before the request; tokens are added
  when the answer arrives, so the token cap can be overshot by at most the
  calls already in flight.

  Calls made with `budget: :qa` (QA audits and evaluation sessions: their
  questions, judge, rule rewrites and the bot's answers to them) count
  against a budget of their own instead (`limits.qa_calls_daily`,
  `limits.qa_tokens_daily`), so evaluating bots never starves the answers
  people are waiting for, nor the other way round.
  """

  require Logger

  alias AgentManager.KV
  alias AgentManager.Showcase.{Limits, Settings}

  @doc "Reserves one model call in `scope` (`nil` or `:qa`), or refuses it when today's budget is spent."
  def reserve_call(scope \\ nil) do
    day = Limits.today()

    cond do
      over?(limit(scope, "tokens"), KV.counter(tokens_key(scope, day))) ->
        refuse(scope, :tokens)

      true ->
        case limit(scope, "calls") do
          nil ->
            :ok

          limit ->
            if KV.incr(calls_key(scope, day)) <= limit do
              :ok
            else
              KV.incr(calls_key(scope, day), -1)
              refuse(scope, :calls)
            end
        end
    end
  end

  @doc "Adds a finished call's tokens to today's budget of `scope`."
  def record(result, scope \\ nil)

  def record({:ok, %{usage: usage}}, scope) when is_map(usage) do
    tokens =
      usage[:total_tokens] || (usage[:prompt_tokens] || 0) + (usage[:completion_tokens] || 0)

    if tokens > 0, do: KV.incr(tokens_key(scope, Limits.today()), tokens)
    :ok
  end

  def record(_result, _scope), do: :ok

  @doc "Whether today's budget of `scope` is spent (checked before starting an answer)."
  def exhausted?(scope \\ nil) do
    day = Limits.today()

    over?(limit(scope, "calls"), KV.counter(calls_key(scope, day))) or
      over?(limit(scope, "tokens"), KV.counter(tokens_key(scope, day)))
  end

  @doc "Today's spend, for the admin API."
  def usage do
    day = Limits.today()

    %{
      "model_calls" => KV.counter(calls_key(nil, day)),
      "model_calls_daily_limit" => limit(nil, "calls"),
      "model_tokens" => KV.counter(tokens_key(nil, day)),
      "model_tokens_daily_limit" => limit(nil, "tokens"),
      "qa_calls" => KV.counter(calls_key(:qa, day)),
      "qa_calls_daily_limit" => limit(:qa, "calls"),
      "qa_tokens" => KV.counter(tokens_key(:qa, day)),
      "qa_tokens_daily_limit" => limit(:qa, "tokens")
    }
  end

  defp limit(nil, kind), do: Settings.limit("model_#{kind}_daily")
  defp limit(:qa, kind), do: Settings.limit("qa_#{kind}_daily")

  defp over?(nil, _used), do: false
  defp over?(limit, used), do: used >= limit

  defp refuse(scope, kind) do
    Logger.warning(
      "[budget] daily #{if scope, do: "#{scope} ", else: ""}model #{kind} budget is spent; refusing the call"
    )

    AgentManager.Events.publish("budget.exhausted", %{kind: kind, scope: scope})
    {:error, :daily_budget_exhausted}
  end

  defp calls_key(nil, day), do: "budget:calls:#{day}"
  defp calls_key(scope, day), do: "budget:#{scope}:calls:#{day}"
  defp tokens_key(nil, day), do: "budget:tokens:#{day}"
  defp tokens_key(scope, day), do: "budget:#{scope}:tokens:#{day}"
end
