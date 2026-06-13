defmodule AgentManager.Training do
  @moduledoc """
  Training is event-driven: `request/3` marks the bot `ON_TRAINING` and
  publishes `training.requested`; `Training.Coordinator` picks it up.
  Progress and outcome arrive as `training.*` events.
  """

  alias AgentManager.{Bots, Events}
  alias AgentManager.Bots.Bot

  @doc "Validates `content` and enqueues a training run for `bot`."
  def request(%Bot{} = bot, content, opts \\ []) do
    content = Bots.normalize_params(content)
    changeset = Bot.Content.changeset(%Bot.Content{}, content)

    if changeset.valid? do
      {:ok, bot} =
        Bots.set_training_info(bot, %{
          "status" => "ON_TRAINING",
          "error_messages" => [],
          "data_json" => content,
          "duration" => 0,
          "timestamp" => DateTime.utc_now()
        })

      Events.publish("training.requested", %{content: content, overload: !!opts[:overload]},
        bot_id: bot.id
      )

      {:ok, bot}
    else
      {:error, changeset}
    end
  end
end

defmodule AgentManager.Training.Coordinator do
  @moduledoc """
  Consumes `training.requested` events and runs training jobs.

    * at most `:max_concurrency` jobs run at once (config, default 2);
      further requests wait in a FIFO queue
    * one job per bot: a request for a bot that is already training replaces
      any request still waiting for it (latest content wins)
    * jobs are tasks under `AgentManager.Training.TaskSupervisor`, not linked
      to the coordinator: a crashing job is reported as `training.failed` and
      the coordinator carries on
  """

  use GenServer
  require Logger

  alias AgentManager.{Bots, Events}
  alias AgentManager.Pipelines.Training, as: TrainingPipeline

  @tasks AgentManager.Training.TaskSupervisor

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Running bot ids and queued bot ids (introspection / tests)."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    Events.subscribe("training.requested")

    max =
      opts[:max_concurrency] ||
        Application.get_env(:agent_manager, __MODULE__, [])[:max_concurrency] || 2

    {:ok, %{max: max, running: %{}, refs: %{}, queue: :queue.new(), pending: %{}}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running: Map.keys(state.running), queued: :queue.to_list(state.queue)}, state}
  end

  @impl true
  def handle_info({:event, %{type: "training.requested"} = event}, state) do
    request = %{bot_id: event.bot_id, payload: event.payload, correlation_id: event.id}

    state =
      if Map.has_key?(state.pending, event.bot_id) do
        put_in(state.pending[event.bot_id], request)
      else
        %{
          state
          | pending: Map.put(state.pending, event.bot_id, request),
            queue: :queue.in(event.bot_id, state.queue)
        }
      end

    {:noreply, drain(state)}
  end

  def handle_info({ref, _result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish(ref) |> drain()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.refs, ref) do
    bot_id = state.refs[ref]
    Logger.error("[training] job for #{bot_id} crashed: #{inspect(reason)}")

    Events.publish(
      "training.failed",
      %{errors: ["job crashed: #{inspect(reason)}"], duration_ms: 0, content: nil},
      bot_id: bot_id
    )

    {:noreply, state |> finish(ref) |> drain()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish(state, ref) do
    {bot_id, refs} = Map.pop(state.refs, ref)
    %{state | refs: refs, running: Map.delete(state.running, bot_id)}
  end

  # Start queued jobs while there is capacity. A bot that is still running is
  # skipped (it stays queued) so its jobs never overlap.
  defp drain(state) do
    if map_size(state.running) >= state.max,
      do: state,
      else: start_next(state, :queue.len(state.queue))
  end

  defp start_next(state, 0), do: state

  defp start_next(state, remaining) do
    {{:value, bot_id}, queue} = :queue.out(state.queue)

    if Map.has_key?(state.running, bot_id) do
      start_next(%{state | queue: :queue.in(bot_id, queue)}, remaining - 1)
    else
      {request, pending} = Map.pop(state.pending, bot_id)
      task = Task.Supervisor.async_nolink(@tasks, fn -> run(request) end)

      drain(%{
        state
        | queue: queue,
          pending: pending,
          running: Map.put(state.running, bot_id, task.pid),
          refs: Map.put(state.refs, task.ref, bot_id)
      })
    end
  end

  @doc false
  def run(%{bot_id: bot_id, payload: payload, correlation_id: correlation_id}) do
    started = System.monotonic_time(:millisecond)
    elapsed = fn -> System.monotonic_time(:millisecond) - started end

    case Bots.get(bot_id) do
      nil ->
        Events.publish(
          "training.failed",
          %{errors: ["bot not found"], duration_ms: 0, content: payload.content}, bot_id: bot_id)

      bot ->
        Events.publish("training.started", %{}, bot_id: bot_id, correlation_id: correlation_id)

        case TrainingPipeline.run(payload, bot: bot, id: correlation_id) do
          {:ok, ctx} ->
            Events.publish(
              "training.completed",
              %{
                stats: ctx.result,
                duration_ms: elapsed.(),
                content: payload.content,
                source_errors: Map.get(ctx.assigns, :source_errors, [])
              },
              bot_id: bot_id,
              correlation_id: correlation_id
            )

          {:error, reason, _ctx} ->
            Events.publish(
              "training.failed",
              %{errors: [format(reason)], duration_ms: elapsed.(), content: payload.content},
              bot_id: bot_id,
              correlation_id: correlation_id
            )
        end
    end
  end

  defp format({:rules_too_long, message}), do: message
  defp format(%{__exception__: true} = e), do: Exception.message(e)
  defp format(reason), do: inspect(reason)
end
