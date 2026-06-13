defmodule AgentManager.Conversations.Message do
  @moduledoc """
  One exchange in a conversation. As in the 1.0 API, a record holds the
  user's `message` and/or the bot's `response` (the answer map); either side
  can be nil when a message was inserted manually.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :bot_id, :binary_id
    field :user_id, :string
    field :message, :string
    field :response, :map
    field :is_response, :boolean, default: false
    field :flags, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:bot_id, :user_id, :message, :response, :is_response, :flags, :inserted_at])
    |> validate_required([:bot_id, :user_id])
    |> then(
      &if(get_field(&1, :inserted_at),
        do: &1,
        else: put_change(&1, :inserted_at, DateTime.utc_now())
      )
    )
  end
end

defmodule AgentManager.Usage.LlmCall do
  @moduledoc "One model call, for cost/latency accounting."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "llm_calls" do
    field :bot_id, :binary_id
    field :correlation_id, :string
    field :model, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :key_hint, :string
    field :latency_ms, :integer
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :bot_id,
      :correlation_id,
      :model,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :key_hint,
      :latency_ms
    ])
    |> put_change(:inserted_at, DateTime.utc_now())
  end
end

defmodule AgentManager.Knowledge.Segment do
  @moduledoc "A chunk of a bot's knowledge with its embedding."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "segments" do
    field :bot_id, :binary_id
    field :segment, :string
    field :cleaned_segment, :string
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string
    field :index, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
