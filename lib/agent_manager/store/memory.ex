defmodule AgentManager.Store.Memory do
  @moduledoc """
  ETS-backed `AgentManager.Store` and `AgentManager.VectorStore`.

  The tables are owned by this GenServer (so they survive the callers) and are
  `:public` with read concurrency: reads go straight to ETS, writes are plain
  ETS inserts. Data lives as long as the node does.
  """
  @behaviour AgentManager.Store

  use GenServer

  alias AgentManager.Bots.Bot
  alias AgentManager.Conversations.Message

  @bots :memory_bots
  @messages :memory_messages
  @calls :memory_llm_calls
  @segments :memory_segments

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Empties every table (tests)."
  def reset, do: Enum.each([@bots, @messages, @calls, @segments], &:ets.delete_all_objects/1)

  @impl GenServer
  def init(:ok) do
    for table <- [@bots, @messages, @calls, @segments] do
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, nil}
  end

  # -- bots --------------------------------------------------------------

  @impl AgentManager.Store
  def get_bot(id) do
    case :ets.lookup(@bots, id) do
      [{_, bot}] -> bot
      [] -> Enum.find(all_bots(), &(&1.identifier == id))
    end
  end

  @impl AgentManager.Store
  def list_bots(cursor, size) do
    bots = Enum.sort_by(all_bots(), &{&1.inserted_at, &1.id}, fn a, b -> compare(a, b) != :gt end)

    page =
      case cursor && get_bot(cursor) do
        %Bot{id: id} -> bots |> Enum.drop_while(&(&1.id != id)) |> Enum.drop(1)
        _ -> bots
      end

    {length(bots), Enum.take(page, size)}
  end

  defp compare({t1, id1}, {t2, id2}) do
    case DateTime.compare(t1, t2) do
      :eq -> if id1 <= id2, do: :lt, else: :gt
      other -> other
    end
  end

  @impl AgentManager.Store
  def get_bots(ids), do: Enum.filter(all_bots(), &(&1.id in ids or &1.identifier in ids))

  @impl AgentManager.Store
  def insert_bot(changeset) do
    if changeset.valid? and taken?(Ecto.Changeset.get_field(changeset, :identifier), nil) do
      {:error, Ecto.Changeset.add_error(changeset, :identifier, "has already been taken")}
    else
      now = DateTime.utc_now()

      with {:ok, bot} <- Ecto.Changeset.apply_action(changeset, :insert) do
        bot = %{bot | id: Ecto.UUID.generate(), inserted_at: now, updated_at: now}
        :ets.insert(@bots, {bot.id, bot})
        {:ok, bot}
      end
    end
  end

  @impl AgentManager.Store
  def update_bot(changeset) do
    id = changeset.data.id

    cond do
      # like Ecto's stale-entry check: never resurrect a deleted bot
      :ets.lookup(@bots, id) == [] ->
        {:error, Ecto.Changeset.add_error(changeset, :id, "does not exist")}

      changeset.valid? and taken?(Ecto.Changeset.get_field(changeset, :identifier), id) ->
        {:error, Ecto.Changeset.add_error(changeset, :identifier, "has already been taken")}

      true ->
        write_update(changeset, id)
    end
  end

  defp write_update(changeset, id) do
    with {:ok, bot} <- Ecto.Changeset.apply_action(changeset, :update) do
      # re-read so concurrent counter updates (total_tokens) are not lost
      tokens =
        case :ets.lookup(@bots, id) do
          [{_, current}] -> current.total_tokens
          [] -> bot.total_tokens
        end

      bot = %{bot | updated_at: DateTime.utc_now(), total_tokens: tokens}
      :ets.insert(@bots, {id, bot})
      {:ok, bot}
    end
  end

  defp taken?(identifier, own_id),
    do: Enum.any?(all_bots(), &(&1.identifier == identifier and &1.id != own_id))

  @impl AgentManager.Store
  def delete_bot(bot) do
    :ets.delete(@bots, bot.id)
    :ets.match_delete(@messages, {:_, bot.id, :_, :_})
    {:ok, bot}
  end

  @impl AgentManager.Store
  def add_bot_tokens(bot_id, tokens) do
    case :ets.lookup(@bots, bot_id) do
      [{_, bot}] -> :ets.insert(@bots, {bot_id, %{bot | total_tokens: bot.total_tokens + tokens}})
      [] -> :ok
    end

    :ok
  end

  defp all_bots, do: :ets.tab2list(@bots) |> Enum.map(&elem(&1, 1))

  # -- messages -------------------------------------------------------------

  @impl AgentManager.Store
  def insert_message(attrs) do
    with {:ok, msg} <-
           %Message{} |> Message.changeset(attrs) |> Ecto.Changeset.apply_action(:insert) do
      msg = %{msg | id: Ecto.UUID.generate()}
      :ets.insert(@messages, {msg.id, msg.bot_id, msg.user_id, msg})
      {:ok, msg}
    end
  end

  @impl AgentManager.Store
  def list_messages(bot_id, user_id, opts) do
    since = opts[:since]

    @messages
    |> :ets.match_object({:_, bot_id, user_id, :_})
    |> Enum.map(&elem(&1, 3))
    |> Enum.filter(&(is_nil(since) or DateTime.compare(&1.inserted_at, since) != :lt))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.take(-(opts[:limit] || 100))
  end

  @impl AgentManager.Store
  def delete_messages(bot_id, user_id) do
    :ets.match_delete(@messages, {:_, bot_id, user_id, :_})
    :ok
  end

  @impl AgentManager.Store
  def flag_last_user_message(bot_id, user_id, flags) do
    bot_id
    |> list_messages(user_id, [])
    |> Enum.filter(&(!&1.is_response))
    |> List.last()
    |> case do
      nil ->
        :ok

      msg ->
        :ets.insert(
          @messages,
          {msg.id, bot_id, user_id, %{msg | flags: Map.merge(msg.flags || %{}, flags)}}
        )
    end

    :ok
  end

  @impl AgentManager.Store
  def insert_llm_call(attrs) do
    :ets.insert(@calls, {Ecto.UUID.generate(), Map.put(attrs, :inserted_at, DateTime.utc_now())})
    :ok
  end

  def llm_calls, do: @calls |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  # -- vectors (AgentManager.VectorStore) -----------------------------------

  defmodule Vectors do
    @moduledoc "In-memory `AgentManager.VectorStore` (brute-force cosine search)."
    @behaviour AgentManager.VectorStore

    alias AgentManager.NLP.Text

    @segments :memory_segments

    @impl true
    def list(bot_id) do
      @segments
      |> :ets.match_object({:_, bot_id, :_})
      |> Enum.map(fn {id, _, seg} ->
        %{id: id, segment: seg.segment, embedding_model: seg.embedding_model}
      end)
    end

    @impl true
    def replace(bot_id, keep_ids, new) do
      stale = bot_id |> list() |> Enum.reject(&(&1.id in keep_ids))
      Enum.each(stale, &:ets.delete(@segments, &1.id))

      for seg <- new do
        id = Ecto.UUID.generate()
        :ets.insert(@segments, {id, bot_id, Map.put(seg, :id, id)})
      end

      {:ok, %{inserted: length(new), deleted: length(stale)}}
    end

    @impl true
    def search(bot_id, embedding, model, k) do
      @segments
      |> :ets.match_object({:_, bot_id, :_})
      |> Enum.map(&elem(&1, 2))
      |> Enum.filter(&(&1.embedding_model == model))
      |> Enum.map(
        &%{
          id: &1.id,
          segment: &1.segment,
          index: &1.index,
          score: Text.cosine(embedding, &1.embedding)
        }
      )
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(k)
    end

    @impl true
    def count(bot_id), do: length(:ets.match_object(@segments, {:_, bot_id, :_}))

    @impl true
    def delete_all(bot_id) do
      :ets.match_delete(@segments, {:_, bot_id, :_})
      :ok
    end
  end
end
