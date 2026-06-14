defmodule AgentManager.Store do
  @moduledoc """
  Persistence boundary for bots, messages and usage records.

      config :agent_manager, :store, AgentManager.Store.Ecto     # Postgres (default)
      config :agent_manager, :store, AgentManager.Store.Memory   # ETS, no database

  The in-memory store makes the whole system runnable without infrastructure
  (tests, demos, local hacking); the Ecto store is what production uses.
  """

  alias AgentManager.Bots.Bot
  alias AgentManager.Conversations.Message

  @callback get_bot(id_or_identifier :: String.t()) :: Bot.t() | nil
  @callback list_bots(cursor :: String.t() | nil, size :: pos_integer()) ::
              {non_neg_integer(), [Bot.t()]}
  @callback get_bots([String.t()]) :: [Bot.t()]
  @callback insert_bot(Ecto.Changeset.t()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  @callback update_bot(Ecto.Changeset.t()) :: {:ok, Bot.t()} | {:error, Ecto.Changeset.t()}
  @callback delete_bot(Bot.t()) :: {:ok, Bot.t()}
  @callback add_bot_tokens(bot_id :: String.t(), tokens :: integer()) :: :ok

  @callback insert_message(map()) :: {:ok, Message.t()} | {:error, term()}
  @callback list_messages(bot_id :: String.t(), user_id :: String.t(), opts :: keyword()) :: [
              Message.t()
            ]
  @callback delete_messages(bot_id :: String.t(), user_id :: String.t()) :: :ok
  @callback flag_last_user_message(bot_id :: String.t(), user_id :: String.t(), flags :: map()) ::
              :ok

  @callback insert_llm_call(map()) :: :ok

  @doc "Bots whose training_info.status is ON_TRAINING (used to recover the training queue)."
  @callback list_training_bots() :: [Bot.t()]

  def impl, do: Application.get_env(:agent_manager, :store, AgentManager.Store.Ecto)

  @doc false
  def uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end

defmodule AgentManager.VectorStore do
  @moduledoc """
  Storage and nearest-neighbour search for knowledge segments.

      config :agent_manager, :vector_store, AgentManager.VectorStore.Pgvector
      config :agent_manager, :vector_store, AgentManager.VectorStore.Memory

  Segments remember which embedding model produced them, and searches only
  consider segments of the query's model - so a bot can switch embedding
  models safely (it needs a retrain to get results again).
  """

  @type segment :: %{
          optional(:id) => String.t(),
          segment: String.t(),
          cleaned_segment: String.t(),
          embedding: [float()],
          embedding_model: String.t(),
          index: non_neg_integer()
        }
  @type hit :: %{id: String.t(), segment: String.t(), index: non_neg_integer(), score: float()}

  @callback list(bot_id :: String.t()) :: [
              %{id: String.t(), segment: String.t(), embedding_model: String.t()}
            ]
  @callback replace(bot_id :: String.t(), keep_ids :: [String.t()], new :: [segment()]) ::
              {:ok, %{inserted: non_neg_integer(), deleted: non_neg_integer()}}
  @callback search(
              bot_id :: String.t(),
              embedding :: [float()],
              model :: String.t(),
              k :: pos_integer()
            ) :: [hit()]
  @callback count(bot_id :: String.t()) :: non_neg_integer()
  @callback delete_all(bot_id :: String.t()) :: :ok

  def impl,
    do: Application.get_env(:agent_manager, :vector_store, AgentManager.VectorStore.Pgvector)
end
