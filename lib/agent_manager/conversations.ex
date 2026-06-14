defmodule AgentManager.Conversations do
  @moduledoc """
  Public API for conversations. Each `{bot_id, user_id}` pair gets its own
  `Conversations.Server` process, started on first use.

  Why a process per conversation:

    * messages from one user are handled strictly in order (no interleaved
      answers built on stale history), while different users run in parallel
    * the live history is kept in memory, so answering never waits on the
      asynchronous persistence done by `Handlers.MessageRecorder`
    * inactivity/NPS timers are just `Process.send_after/3`
  """

  alias AgentManager.Bots.Bot
  alias AgentManager.Conversations.Server
  alias AgentManager.Pipelines.Answer

  @registry AgentManager.Conversations.Registry
  @supervisor AgentManager.Conversations.Supervisor

  @doc "Answers `text` from `user_id`. Returns `{:ok, %Answer{}, ctx}`."
  def ask(%Bot{} = bot, user_id, text), do: call(bot, user_id, {:ask, bot, text}, 180_000)

  @doc "Records a message produced outside the bot (`:user` or `:bot` side)."
  def record(%Bot{} = bot, user_id, side, text, flags \\ []) when side in [:user, :bot],
    do: call(bot, user_id, {:record, side, text, flags}, 15_000)

  @doc "The prompt the bot would send for `text`, without calling the model or running commands."
  def preview_prompt(%Bot{} = bot, user_id, text) do
    history = call(bot, user_id, :history, 15_000)
    steps = Answer.steps() |> AgentManager.Pipeline.remove(Answer.Steps.RunCommands)

    case Answer.run(%{text: text, user_id: user_id, history: history},
           bot: bot,
           steps: steps,
           until: Answer.Steps.BuildPrompt
         ) do
      {:ok, ctx} -> {:ok, ctx.assigns[:messages] || [], ctx}
      {:error, reason, ctx} -> {:error, reason, ctx}
    end
  end

  def whereis(bot_id, user_id) do
    case Registry.lookup(@registry, {bot_id, user_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def count, do: DynamicSupervisor.count_children(@supervisor).active

  # A process can stop (idle timeout, crash) between the registry lookup and
  # the call, and the registry forgets dead pids asynchronously. `:noproc`
  # means the message was never delivered, so retrying is safe.
  defp call(bot, user_id, message, timeout, attempts \\ 5) do
    GenServer.call(ensure_started(bot.id, user_id), message, timeout)
  catch
    :exit, {:noproc, _} when attempts > 1 ->
      Process.sleep(10)
      call(bot, user_id, message, timeout, attempts - 1)
  end

  defp ensure_started(bot_id, user_id) do
    case DynamicSupervisor.start_child(@supervisor, {Server, bot_id: bot_id, user_id: user_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  def via(bot_id, user_id), do: {:via, Registry, {@registry, {bot_id, user_id}}}
end

defmodule AgentManager.Conversations.Server do
  @moduledoc false
  # Temporary: a conversation is rebuilt on demand (history reloads from the
  # store), so there is nothing to gain from restarting it automatically.
  use GenServer, restart: :temporary
  require Logger

  alias AgentManager.{Answer, Conversations, Events, Store}
  alias AgentManager.Conversations.Message
  alias AgentManager.Pipelines.Answer, as: AnswerPipeline

  @history_limit 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Conversations.via(opts[:bot_id], opts[:user_id]))
  end

  @impl true
  def init(opts) do
    state = %{
      bot_id: opts[:bot_id],
      user_id: opts[:user_id],
      history: nil,
      timers: %{},
      last_activity: nil
    }

    {:ok, state, idle_timeout()}
  end

  # History is loaded lazily so starting a process never blocks on the store.
  defp load(%{history: nil} = state) do
    %{
      state
      | history: Store.impl().list_messages(state.bot_id, state.user_id, limit: @history_limit)
    }
  end

  defp load(state), do: state

  @impl true
  def handle_call({:ask, bot, text}, _from, state) do
    state = load(state)
    publish(state, "message.received", %{text: text})

    result =
      AnswerPipeline.run(%{text: text, user_id: state.user_id, history: state.history}, bot: bot)

    {reply, state} =
      case result do
        {:ok, %{result: %Answer{} = answer} = ctx} ->
          {{:ok, answer, ctx}, after_answer(state, bot, text, answer, ctx)}

        {:ok, ctx} ->
          {{:error, :no_answer, ctx}, state}

        {:error, reason, ctx} ->
          {{:error, reason, ctx}, state}
      end

    {:reply, reply, state, idle_timeout()}
  end

  def handle_call({:record, side, text, flags}, _from, state) do
    state = load(state)
    flag_map = Map.new(flags, &{to_string(&1), true})

    attrs =
      case side do
        :user ->
          %{message: text, response: nil, is_response: true}

        :bot ->
          %{
            message: nil,
            response: Answer.to_map(Answer.new(text)),
            is_response: true,
            flags: flag_map
          }
      end
      |> Map.merge(%{
        bot_id: state.bot_id,
        user_id: state.user_id,
        inserted_at: DateTime.utc_now()
      })

    publish(state, "message.recorded", %{
      message: attrs,
      flag_last_user_message: if(side == :bot and flags != [], do: flag_map)
    })

    {:reply, :ok, append(state, attrs), idle_timeout()}
  end

  def handle_call(:history, _from, state) do
    state = load(state)
    {:reply, state.history, state, idle_timeout()}
  end

  @impl true
  def handle_info({:timer, kind, minutes, token}, state) do
    # A newer message re-arms the timers with a new token, so stale ones are ignored.
    if match?(%{^kind => ^token}, state.timers) do
      publish(state, "conversation.#{kind}", %{minutes: minutes})
    end

    {:noreply, %{state | timers: Map.delete(state.timers, kind)}, idle_timeout()}
  end

  def handle_info(:timeout, state) do
    if map_size(state.timers) == 0,
      do: {:stop, :normal, state},
      else: {:noreply, state, :hibernate}
  end

  defp after_answer(state, bot, text, answer, ctx) do
    effects = ctx.assigns[:effects] || []

    state =
      if :clear_history in effects do
        publish(state, "conversation.cleared", %{})
        %{state | history: []}
      else
        state
      end

    persist? = not answer.error and not Map.get(ctx.assigns, :skip_persist, false)
    ended? = answer.metadata[:is_end_of_conversation] == true

    attrs = %{
      bot_id: state.bot_id,
      user_id: state.user_id,
      message: text,
      response: Answer.to_map(answer),
      is_response: false,
      flags: if(ended?, do: %{"inactive_minutes" => true, "nps_minutes" => true}, else: %{}),
      inserted_at: DateTime.utc_now()
    }

    publish(
      state,
      "message.answered",
      %{
        text: text,
        answer: Answer.to_map(answer),
        usage: ctx.usage,
        persist: persist?,
        record: attrs
      },
      correlation_id: ctx.id
    )

    state = if persist?, do: append(state, attrs), else: state
    if ended?, do: cancel_timers(state), else: arm_timers(state, bot)
  end

  defp append(state, attrs) do
    message = struct(Message, attrs)
    %{state | history: Enum.take(state.history ++ [message], -@history_limit)}
  end

  defp arm_timers(state, bot) do
    state = cancel_timers(state)
    timings = bot.job_timings || %{inactive_minutes: nil, nps_minutes: nil}

    timers =
      for {kind, minutes} <- [inactive: timings.inactive_minutes, nps_due: timings.nps_minutes],
          is_integer(minutes) and minutes > 0,
          into: %{} do
        token = make_ref()
        Process.send_after(self(), {:timer, kind, minutes, token}, minutes * minute_ms())
        {kind, token}
      end

    %{state | timers: timers}
  end

  defp cancel_timers(state), do: %{state | timers: %{}}

  defp publish(state, type, payload, opts \\ []) do
    Events.publish(
      type,
      Map.put(payload, :user_id, state.user_id),
      Keyword.put(opts, :bot_id, state.bot_id)
    )
  end

  defp idle_timeout do
    Application.get_env(:agent_manager, __MODULE__, [])[:idle_timeout] || :timer.minutes(30)
  end

  # Length of one "minute" for job timings (shortened in tests).
  defp minute_ms, do: Application.get_env(:agent_manager, __MODULE__, [])[:minute_ms] || 60_000
end
