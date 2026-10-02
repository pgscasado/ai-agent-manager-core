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
  """

  require Logger

  alias AgentManager.KV
  alias AgentManager.Showcase.{Limits, Settings}

  @doc "Reserves one model call, or refuses it when today's budget is spent."
  def reserve_call do
    day = Limits.today()

    cond do
      over?(Settings.limit("model_tokens_daily"), KV.counter(tokens_key(day))) ->
        refuse(:tokens)

      true ->
        case Settings.limit("model_calls_daily") do
          nil ->
            :ok

          limit ->
            if KV.incr(calls_key(day)) <= limit do
              :ok
            else
              KV.incr(calls_key(day), -1)
              refuse(:calls)
            end
        end
    end
  end

  @doc "Adds a finished call's tokens to today's budget."
  def record({:ok, %{usage: usage}}) when is_map(usage) do
    tokens =
      usage[:total_tokens] || (usage[:prompt_tokens] || 0) + (usage[:completion_tokens] || 0)

    if tokens > 0, do: KV.incr(tokens_key(Limits.today()), tokens)
    :ok
  end

  def record(_result), do: :ok

  @doc "Whether today's budget is spent (checked before starting an answer)."
  def exhausted? do
    day = Limits.today()

    over?(Settings.limit("model_calls_daily"), KV.counter(calls_key(day))) or
      over?(Settings.limit("model_tokens_daily"), KV.counter(tokens_key(day)))
  end

  @doc "Today's spend, for the admin API."
  def usage do
    day = Limits.today()

    %{
      "model_calls" => KV.counter(calls_key(day)),
      "model_calls_daily_limit" => Settings.limit("model_calls_daily"),
      "model_tokens" => KV.counter(tokens_key(day)),
      "model_tokens_daily_limit" => Settings.limit("model_tokens_daily")
    }
  end

  defp over?(nil, _used), do: false
  defp over?(limit, used), do: used >= limit

  defp refuse(kind) do
    Logger.warning("[budget] daily model #{kind} budget is spent; refusing the call")
    AgentManager.Events.publish("budget.exhausted", %{kind: kind})
    {:error, :daily_budget_exhausted}
  end

  defp calls_key(day), do: "budget:calls:#{day}"
  defp tokens_key(day), do: "budget:tokens:#{day}"
end
