defmodule AgentManager.Models.RateLimiter do
  @moduledoc """
  Per-provider request pacing (sliding window), for providers with hard
  limits such as free-tier keys.

      config :agent_manager, AgentManager.Models,
        providers: [gemini: [..., rate_limit: {5, :minute}, max_retries: 3]]

  One process per provider, started on first use under
  `AgentManager.Models.LimiterSupervisor`. Callers that exceed the window
  wait in FIFO order - they are not rejected - so a burst of conversations is
  smoothed out instead of failing with 429s.
  """

  use GenServer

  @registry AgentManager.Models.Registry
  @supervisor AgentManager.Models.LimiterSupervisor

  @doc "Blocks until `provider` may send another request under `limit`."
  def acquire(provider, limit, timeout \\ 300_000) do
    {requests, window_ms} = normalize(limit)
    GenServer.call(ensure_started(provider), {:acquire, requests, window_ms}, timeout)
  end

  def normalize({n, :second}), do: {n, 1_000}
  def normalize({n, :minute}), do: {n, 60_000}
  def normalize({n, :hour}), do: {n, 3_600_000}
  def normalize({n, ms}) when is_integer(ms), do: {n, ms}
  def normalize(n) when is_integer(n), do: {n, 60_000}

  defp ensure_started(provider) do
    name = {:via, Registry, {@registry, {:rate_limiter, provider}}}

    case DynamicSupervisor.start_child(@supervisor, %{
           id: provider,
           start: {GenServer, :start_link, [__MODULE__, provider, [name: name]]},
           restart: :transient
         }) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(provider),
    do: {:ok, %{provider: provider, sent: :queue.new(), waiting: :queue.new(), timer: nil}}

  @impl true
  def handle_call({:acquire, requests, window_ms}, from, state) do
    state = %{state | waiting: :queue.in({from, requests, window_ms}, state.waiting)}
    {:noreply, serve(state)}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, serve(%{state | timer: nil})}

  # Grant slots to waiting callers, oldest first, while the window allows.
  defp serve(state) do
    now = System.monotonic_time(:millisecond)

    case :queue.peek(state.waiting) do
      :empty ->
        state

      {:value, {from, requests, window_ms}} ->
        sent = drop_older(state.sent, now - window_ms)

        if :queue.len(sent) < requests do
          GenServer.reply(from, :ok)
          serve(%{state | sent: :queue.in(now, sent), waiting: :queue.drop(state.waiting)})
        else
          {:value, oldest} = :queue.peek(sent)
          schedule(%{state | sent: sent}, oldest + window_ms - now)
        end
    end
  end

  defp drop_older(sent, cutoff) do
    case :queue.peek(sent) do
      {:value, t} when t <= cutoff -> drop_older(:queue.drop(sent), cutoff)
      _ -> sent
    end
  end

  defp schedule(%{timer: nil} = state, delay),
    do: %{state | timer: Process.send_after(self(), :tick, max(delay, 1))}

  defp schedule(state, _delay), do: state
end
