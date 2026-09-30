defmodule AgentManager.Handlers.MessageRecorder do
  @moduledoc "Persists conversation messages from `message.answered` / `message.recorded`."
  use AgentManager.Events.Handler, subscribe: ["message.answered", "message.recorded"]

  alias AgentManager.Store

  @impl true
  def handle_event(%{type: "message.answered", payload: %{persist: true, record: record}}, state) do
    {:ok, _} = Store.impl().insert_message(record)
    {:ok, state}
  end

  def handle_event(%{type: "message.recorded", bot_id: bot_id, payload: payload}, state) do
    if flags = payload[:flag_last_user_message] do
      Store.impl().flag_last_user_message(bot_id, payload.user_id, flags)
    end

    {:ok, _} = Store.impl().insert_message(payload.message)
    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}
end

defmodule AgentManager.Handlers.UsageRecorder do
  @moduledoc "Records every model call (`llm.completed`) and keeps each bot's token counter."
  use AgentManager.Events.Handler, subscribe: ["llm.completed"]

  alias AgentManager.Store

  @impl true
  def handle_event(%{bot_id: bot_id, correlation_id: cid, payload: p}, state) do
    Store.impl().insert_llm_call(%{
      bot_id: bot_id,
      correlation_id: cid,
      model: p.model,
      prompt_tokens: p.usage.prompt_tokens,
      completion_tokens: p.usage.completion_tokens,
      total_tokens: p.usage.total_tokens,
      key_hint: p.key_hint,
      latency_ms: p.latency_ms
    })

    if bot_id, do: Store.impl().add_bot_tokens(bot_id, p.usage.total_tokens)
    {:ok, state}
  end
end

defmodule AgentManager.Handlers.TrainingRecorder do
  @moduledoc "Writes training outcome (`FINISHED` / `ERROR`) onto the bot."
  use AgentManager.Events.Handler, subscribe: ["training.completed", "training.failed"]

  alias AgentManager.Bots

  @impl true
  def handle_event(%{type: type, bot_id: bot_id, payload: p}, state) do
    with {:ok, bot} <- Bots.fetch(bot_id) do
      {status, errors} =
        if type == "training.completed",
          do: {"FINISHED", p[:source_errors] || []},
          else: {"ERROR", p.errors}

      Bots.set_training_info(bot, %{
        "status" => status,
        "error_messages" => errors,
        "data_json" => p.content || %{},
        "duration" => p.duration_ms,
        "timestamp" => DateTime.utc_now()
      })
    end

    {:ok, state}
  end
end

defmodule AgentManager.Handlers.EventLogger do
  @moduledoc "Logs every event at debug level (and training/model failures as warnings)."
  use AgentManager.Events.Handler, subscribe: [:all]

  @impl true
  def handle_event(%{type: type} = event, state) when type in ["training.failed", "llm.failed"] do
    Logger.warning("[event] #{type} bot=#{event.bot_id} #{inspect(event.payload)}")
    {:ok, state}
  end

  def handle_event(%{type: "pipeline.step.completed"}, state), do: {:ok, state}

  def handle_event(event, state) do
    # the live trace already prints every event, in more detail
    unless AgentManager.Handlers.LiveTrace.enabled?() do
      Logger.debug(fn ->
        "[event] #{event.type} bot=#{event.bot_id} correlation=#{event.correlation_id}"
      end)
    end

    {:ok, state}
  end
end

defmodule AgentManager.Handlers.Webhooks do
  @moduledoc """
  Forwards selected events to HTTP endpoints - the integration point for the
  platforms that used to poll this API (e.g. to start human attendance or send
  an NPS survey when `conversation.nps_due` fires).

      config :agent_manager, AgentManager.Handlers.Webhooks,
        endpoints: [%{url: "https://example.com/hook", events: ["conversation.inactive", "training.completed"]}]

  Deliveries run in their own tasks, so a slow endpoint never blocks the handler.
  """
  use AgentManager.Events.Handler, subscribe: [:all]

  @impl true
  def init_state(_opts), do: Application.get_env(:agent_manager, __MODULE__, [])[:endpoints] || []

  @impl true
  def handle_event(%{type: "pipeline.step.completed"}, endpoints), do: {:ok, endpoints}

  def handle_event(event, endpoints) do
    for %{url: url, events: types} <- endpoints, event.type in types do
      Task.Supervisor.start_child(AgentManager.TaskSupervisor, fn ->
        Req.post(url, json: Map.from_struct(event), retry: :transient, max_retries: 3)
      end)
    end

    {:ok, endpoints}
  end
end
