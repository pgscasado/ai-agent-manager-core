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
          "timestamp" => DateTime.utc_now(),
          "overload" => !!opts[:overload]
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

  ## Recovery

  The queue lives in this process, but it is never the only copy: every
  request first marks the bot `ON_TRAINING` in the store, with its content
  and flags. So on every start (first boot, a supervisor restart after a
  crash, or a node restart) the coordinator rebuilds its state:

    1. **adopts** jobs that are still running - each job registers itself in
       `AgentManager.Training.Registry`, so a coordinator restarted after a
       crash finds and monitors them instead of starting duplicates
    2. **re-queues** every bot still `ON_TRAINING` without a live job - the
       requests that were waiting, or running when the node went down

  Re-running an interrupted job is safe: training diffs against what is
  already indexed and swaps segments in one transaction.
  """

  use GenServer
  require Logger

  alias AgentManager.{Bots, Events, Store}
  alias AgentManager.Pipelines.Training, as: TrainingPipeline

  @tasks AgentManager.Training.TaskSupervisor
  @registry AgentManager.Training.Registry

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Running bot ids and queued bot ids (introspection / tests)."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    # Subscribe before reading the store, so a request made while we recover
    # is not missed (if it duplicates a recovered one, the two coalesce).
    Events.subscribe("training.requested")

    max =
      opts[:max_concurrency] ||
        Application.get_env(:agent_manager, __MODULE__, [])[:max_concurrency] || 2

    state = %{max: max, running: %{}, refs: %{}, queue: :queue.new(), pending: %{}}
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    state = Enum.reduce(running_jobs(), state, &adopt/2)

    recovered =
      for bot <- Store.impl().list_training_bots(), not Map.has_key?(state.running, bot.id) do
        info = bot.training_info

        %{
          bot_id: bot.id,
          payload: %{content: info.data_json || %{}, overload: info.overload || false},
          correlation_id: Ecto.UUID.generate()
        }
      end

    if state.running != %{} or recovered != [] do
      Logger.info(
        "[training] recovered: adopted #{map_size(state.running)} running job(s), " <>
          "re-queued #{length(recovered)} interrupted request(s)"
      )
    end

    {:noreply, recovered |> Enum.reduce(state, &enqueue/2) |> drain()}
  end

  defp running_jobs,
    do: Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

  defp adopt({bot_id, pid}, state) do
    ref = Process.monitor(pid)

    %{
      state
      | running: Map.put(state.running, bot_id, pid),
        refs: Map.put(state.refs, ref, bot_id)
    }
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running: Map.keys(state.running), queued: :queue.to_list(state.queue)}, state}
  end

  @impl true
  def handle_info({:event, %{type: "training.requested"} = event}, state) do
    request = %{bot_id: event.bot_id, payload: event.payload, correlation_id: event.id}
    {:noreply, request |> enqueue(state) |> drain()}
  end

  def handle_info({ref, _result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish(ref) |> drain()}
  end

  # An adopted job is not our task, so it ends with a plain :normal DOWN
  # (its outcome was already published as an event by the job itself).
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state)
      when is_map_key(state.refs, ref) do
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

  # Queue a request; a bot already waiting keeps its place but takes the newest content.
  defp enqueue(request, state) do
    if Map.has_key?(state.pending, request.bot_id) do
      put_in(state.pending[request.bot_id], request)
    else
      %{
        state
        | pending: Map.put(state.pending, request.bot_id, request),
          queue: :queue.in(request.bot_id, state.queue)
      }
    end
  end

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
    # Registering lets a restarted coordinator find this job (the entry goes
    # away when we exit). The registry is unique per bot, so if recovery ever
    # races a job that had not registered yet, the second one steps aside.
    case Registry.register(@registry, bot_id, nil) do
      {:ok, _} -> do_run(bot_id, payload, correlation_id)
      {:error, {:already_registered, _pid}} -> :duplicate
    end
  end

  defp do_run(bot_id, payload, correlation_id) do
    started = System.monotonic_time(:millisecond)
    elapsed = fn -> System.monotonic_time(:millisecond) - started end

    case Bots.get(bot_id) do
      nil ->
        Events.publish(
          "training.failed",
          %{errors: ["bot not found"], duration_ms: 0, content: payload.content},
          bot_id: bot_id
        )

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
