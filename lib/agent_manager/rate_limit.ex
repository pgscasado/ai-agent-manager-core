defmodule AgentManager.RateLimit do
  @moduledoc """
  Fixed-window rate limiting in ETS: `hit(bucket, key, limit, window_ms)`
  counts one event and says whether `key` is over `limit` in the current
  window. Used for per-IP limits on HTTP routes, failed-login lockouts and
  per-number WhatsApp floods.

  Counters live in memory on this node (they're short-lived; a restart simply
  starts fresh windows). A sweep drops expired windows every minute.
  """
  use GenServer

  @table :rate_limits
  @sweep :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Counts one event; `:ok` while within `limit`, `{:error, retry_after_seconds}` beyond it."
  def hit(bucket, key, limit, window_ms) do
    {window, expires_at} = window(window_ms)

    count =
      :ets.update_counter(
        @table,
        {bucket, key, window},
        {2, 1},
        {{bucket, key, window}, 0, expires_at}
      )

    if count <= limit, do: :ok, else: {:error, retry_after(expires_at)}
  end

  @doc "Events counted for `key` in the current window."
  def count(bucket, key, window_ms) do
    {window, _} = window(window_ms)

    case :ets.lookup(@table, {bucket, key, window}) do
      [{_, count, _}] -> count
      [] -> 0
    end
  end

  @doc "Seconds until the current window of `window_ms` ends."
  def retry_after_seconds(window_ms) do
    {_, expires_at} = window(window_ms)
    retry_after(expires_at)
  end

  @doc "Forgets every counter (tests)."
  def reset, do: :ets.delete_all_objects(@table)

  defp window(window_ms) do
    now = System.system_time(:millisecond)
    index = div(now, window_ms)
    {{window_ms, index}, (index + 1) * window_ms}
  end

  defp retry_after(expires_at),
    do: max(div(expires_at - System.system_time(:millisecond), 1000), 1)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
