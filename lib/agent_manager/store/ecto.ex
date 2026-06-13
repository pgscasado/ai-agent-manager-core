defmodule AgentManager.Store.Ecto do
  @moduledoc "Postgres-backed `AgentManager.Store`."
  @behaviour AgentManager.Store

  import Ecto.Query

  alias AgentManager.Repo
  alias AgentManager.Bots.Bot
  alias AgentManager.Conversations.Message
  alias AgentManager.Usage.LlmCall

  @impl true
  def get_bot(id) do
    if AgentManager.Store.uuid?(id),
      do: Repo.get(Bot, id) || Repo.get_by(Bot, identifier: id),
      else: Repo.get_by(Bot, identifier: id)
  end

  @impl true
  def list_bots(cursor, size) do
    query = from(b in Bot, order_by: [asc: b.inserted_at, asc: b.id], limit: ^size)

    query =
      case cursor && get_bot(cursor) do
        %Bot{inserted_at: at, id: id} ->
          where(query, [b], b.inserted_at > ^at or (b.inserted_at == ^at and b.id > ^id))

        _ ->
          query
      end

    {Repo.aggregate(Bot, :count), Repo.all(query)}
  end

  @impl true
  def get_bots(ids) do
    uuids = Enum.filter(ids, &AgentManager.Store.uuid?/1)
    Repo.all(from b in Bot, where: b.id in ^uuids or b.identifier in ^ids)
  end

  @impl true
  def insert_bot(changeset), do: Repo.insert(changeset)

  @impl true
  def update_bot(changeset), do: Repo.update(changeset)

  @impl true
  def delete_bot(bot) do
    Repo.delete_all(from m in Message, where: m.bot_id == ^bot.id)
    Repo.delete(bot)
  end

  @impl true
  def add_bot_tokens(bot_id, tokens) do
    Repo.update_all(from(b in Bot, where: b.id == ^bot_id), inc: [total_tokens: tokens])
    :ok
  end

  @impl true
  def insert_message(attrs), do: %Message{} |> Message.changeset(attrs) |> Repo.insert()

  @impl true
  def list_messages(bot_id, user_id, opts) do
    since = opts[:since] || ~U[1970-01-01 00:00:00Z]

    from(m in Message,
      where: m.bot_id == ^bot_id and m.user_id == ^user_id and m.inserted_at >= ^since,
      order_by: [desc: m.inserted_at],
      limit: ^(opts[:limit] || 100)
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @impl true
  def delete_messages(bot_id, user_id) do
    Repo.delete_all(from m in Message, where: m.bot_id == ^bot_id and m.user_id == ^user_id)
    :ok
  end

  @impl true
  def flag_last_user_message(bot_id, user_id, flags) do
    last =
      Repo.one(
        from m in Message,
          where: m.bot_id == ^bot_id and m.user_id == ^user_id and m.is_response == false,
          order_by: [desc: m.inserted_at],
          limit: 1
      )

    if last,
      do:
        last |> Message.changeset(%{flags: Map.merge(last.flags || %{}, flags)}) |> Repo.update()

    :ok
  end

  @impl true
  def insert_llm_call(attrs) do
    %LlmCall{} |> LlmCall.changeset(attrs) |> Repo.insert()
    :ok
  end
end

defmodule AgentManager.VectorStore.Pgvector do
  @moduledoc "pgvector-backed `AgentManager.VectorStore` (cosine distance, HNSW index)."
  @behaviour AgentManager.VectorStore

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias AgentManager.Repo
  alias AgentManager.Knowledge.Segment

  @impl true
  def list(bot_id) do
    Repo.all(
      from s in Segment,
        where: s.bot_id == ^bot_id,
        select: %{id: s.id, segment: s.segment, embedding_model: s.embedding_model}
    )
  end

  @impl true
  def replace(bot_id, keep_ids, new) do
    Repo.transaction(fn ->
      {deleted, _} =
        Repo.delete_all(from s in Segment, where: s.bot_id == ^bot_id and s.id not in ^keep_ids)

      now = DateTime.utc_now()

      rows =
        Enum.map(new, fn seg ->
          seg
          |> Map.take([:segment, :cleaned_segment, :embedding_model, :index])
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            bot_id: bot_id,
            embedding: Pgvector.new(seg.embedding),
            inserted_at: now
          })
        end)

      inserted =
        rows
        |> Enum.chunk_every(500)
        |> Enum.map(fn chunk -> chunk |> then(&Repo.insert_all(Segment, &1)) |> elem(0) end)
        |> Enum.sum()

      %{inserted: inserted, deleted: deleted}
    end)
  end

  @impl true
  def search(bot_id, embedding, model, k) do
    vector = Pgvector.new(embedding)

    Repo.all(
      from s in Segment,
        where: s.bot_id == ^bot_id and s.embedding_model == ^model,
        order_by: cosine_distance(s.embedding, ^vector),
        limit: ^k,
        select: %{
          id: s.id,
          segment: s.segment,
          index: s.index,
          score: 1 - cosine_distance(s.embedding, ^vector)
        }
    )
  end

  @impl true
  def count(bot_id), do: Repo.aggregate(from(s in Segment, where: s.bot_id == ^bot_id), :count)

  @impl true
  def delete_all(bot_id) do
    Repo.delete_all(from s in Segment, where: s.bot_id == ^bot_id)
    :ok
  end
end
