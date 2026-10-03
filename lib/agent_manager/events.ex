defmodule AgentManager.Events do
  @moduledoc """
  Event bus on top of `Phoenix.PubSub`.

  Each event is broadcast to three topics so consumers can pick their scope:

    * `"events"` - everything (loggers, auditing)
    * `"events:<type>"` - one event type, e.g. `"events:message.answered"`
    * `"bot:<bot_id>"` - everything about one bot (used by the web channel)

  Because PubSub is distributed, handlers on any node in the cluster receive
  events published on any other node.

  ## Event catalogue

  | type                          | published by           | payload                                |
  |-------------------------------|------------------------|----------------------------------------|
  | `message.received`            | `Conversations.Server` | `user_id, text`                        |
  | `message.answered`            | `Conversations.Server` | `user_id, text, answer, usage`         |
  | `message.recorded`            | `Conversations.Server` | `message` (manual user/bot inserts)    |
  | `conversation.cleared`        | `Conversations.Server` | `user_id`                              |
  | `conversation.inactive`       | `Conversations.Server` | `user_id, minutes`                     |
  | `conversation.nps_due`        | `Conversations.Server` | `user_id, minutes`                     |
  | `llm.completed`               | `Models`               | `model, usage, latency_ms, key_hint`   |
  | `llm.failed`                  | `Models`               | `model, reason, latency_ms`            |
  | `pipeline.step.completed`     | `Pipeline.Runner`      | `pipeline, step, status, duration_us`  |
  | `training.requested`          | `Training`             | `content, overload`                    |
  | `training.started`            | `Training.Coordinator` | `%{}`                                  |
  | `training.progress`           | training steps         | `percent, stage`                       |
  | `training.completed`          | `Training.Job`         | `stats, duration_ms, content`          |
  | `training.failed`             | `Training.Job`         | `errors, duration_ms, content`         |
  | `bot.created/updated/deleted` | `Bots`                 | `bot`                                  |
  | `tool.called`                 | `Generate` step        | `tool, arguments`                      |
  | `tool.completed`              | `Generate` step        | `tool, id, is_error, duration_ms, result` (preview), `content` |
  | `channel.received`            | `Showcase.Session`     | `channel, from, name, type, text, reply_id, filename, state` |
  | `channel.sent`                | `Showcase.Session`     | `channel, to, summary`                 |
  | `channel.send_failed`         | `Showcase.Session`     | `channel, to, summary, reason`         |
  | `showcase.state`              | `Showcase.Session`     | `from, from_state, to_state, bot`      |
  """

  alias AgentManager.Events.Event

  @pubsub AgentManager.PubSub

  @doc "Builds and broadcasts an event. Returns the event."
  @spec publish(Event.type(), map(), keyword()) :: Event.t()
  def publish(type, payload \\ %{}, opts \\ []) do
    event = Event.new(type, payload, opts)
    broadcast(event)
    event
  end

  @spec broadcast(Event.t()) :: :ok
  def broadcast(%Event{} = event) do
    message = {:event, event}
    Phoenix.PubSub.broadcast(@pubsub, "events", message)
    Phoenix.PubSub.broadcast(@pubsub, "events:" <> event.type, message)

    if event.bot_id do
      Phoenix.PubSub.broadcast(@pubsub, "bot:" <> event.bot_id, message)
    end

    :ok
  end

  @doc """
  Subscribes the calling process. Messages arrive as `{:event, %Event{}}`.

      subscribe(:all)
      subscribe("training.progress")
      subscribe({:bot, bot_id})
  """
  @spec subscribe(:all | Event.type() | {:bot, String.t()}) :: :ok | {:error, term()}
  def subscribe(:all), do: Phoenix.PubSub.subscribe(@pubsub, "events")
  def subscribe({:bot, bot_id}), do: Phoenix.PubSub.subscribe(@pubsub, "bot:" <> bot_id)

  def subscribe(type) when is_binary(type),
    do: Phoenix.PubSub.subscribe(@pubsub, "events:" <> type)

  @spec unsubscribe(:all | Event.type() | {:bot, String.t()}) :: :ok
  def unsubscribe(:all), do: Phoenix.PubSub.unsubscribe(@pubsub, "events")
  def unsubscribe({:bot, bot_id}), do: Phoenix.PubSub.unsubscribe(@pubsub, "bot:" <> bot_id)

  def unsubscribe(type) when is_binary(type),
    do: Phoenix.PubSub.unsubscribe(@pubsub, "events:" <> type)
end
