defmodule AgentManager.KV do
  @moduledoc """
  Small key-value storage for state that is not a bot or a message: runtime
  settings, channel sessions, usage counters and the data of demo APIs.

  Values are JSON-encodable terms, grouped by a `scope` string. Counters are
  separate, atomic integers (safe under concurrent increments).

  The backend follows the configured store: ETS tables owned by
  `AgentManager.Store.Memory`, or the `kv_entries` / `kv_counters` tables in
  Postgres.
  """

  @callback get(scope :: String.t(), key :: String.t()) :: term() | nil
  @callback put(scope :: String.t(), key :: String.t(), value :: term()) :: :ok
  @callback delete(scope :: String.t(), key :: String.t()) :: :ok
  @callback list(scope :: String.t()) :: [{String.t(), term()}]
  @callback incr(key :: String.t(), by :: integer()) :: integer()
  @callback counter(key :: String.t()) :: integer()

  def impl do
    case AgentManager.Store.impl() do
      AgentManager.Store.Memory -> AgentManager.KV.Memory
      _ -> AgentManager.KV.Ecto
    end
  end

  def get(scope, key, default \\ nil) do
    case impl().get(scope, key) do
      nil -> default
      value -> value
    end
  end

  def put(scope, key, value), do: impl().put(scope, key, value)
  def delete(scope, key), do: impl().delete(scope, key)
  def list(scope), do: impl().list(scope)

  @doc "Atomically adds `by` to counter `key` and returns the new value."
  def incr(key, by \\ 1), do: impl().incr(key, by)
  def counter(key), do: impl().counter(key)
end

defmodule AgentManager.KV.Memory do
  @moduledoc false
  @behaviour AgentManager.KV

  @kv :memory_kv
  @counters :memory_counters

  @impl true
  def get(scope, key) do
    case :ets.lookup(@kv, {scope, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  @impl true
  def put(scope, key, value) do
    :ets.insert(@kv, {{scope, key}, normalize(value)})
    :ok
  end

  @impl true
  def delete(scope, key) do
    :ets.delete(@kv, {scope, key})
    :ok
  end

  @impl true
  def list(scope) do
    @kv
    |> :ets.match_object({{scope, :_}, :_})
    |> Enum.map(fn {{_, key}, value} -> {key, value} end)
    |> Enum.sort()
  end

  @impl true
  def incr(key, by), do: :ets.update_counter(@counters, key, by, {key, 0})

  @impl true
  def counter(key) do
    case :ets.lookup(@counters, key) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  # Same shape the Postgres backend returns (string keys, JSON types).
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()
end

defmodule AgentManager.KV.Ecto do
  @moduledoc false
  @behaviour AgentManager.KV

  import Ecto.Query
  alias AgentManager.Repo

  # jsonb columns hold maps; other values are wrapped.
  @wrap "__value"

  @impl true
  def get(scope, key) do
    from(e in "kv_entries", where: e.scope == ^scope and e.key == ^key, select: e.value)
    |> Repo.one()
    |> unwrap()
  end

  @impl true
  def put(scope, key, value) do
    Repo.insert_all(
      "kv_entries",
      [%{scope: scope, key: key, value: wrap(value), updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:scope, :key]
    )

    :ok
  end

  @impl true
  def delete(scope, key) do
    Repo.delete_all(from e in "kv_entries", where: e.scope == ^scope and e.key == ^key)
    :ok
  end

  @impl true
  def list(scope) do
    from(e in "kv_entries", where: e.scope == ^scope, order_by: e.key, select: {e.key, e.value})
    |> Repo.all()
    |> Enum.map(fn {k, v} -> {k, unwrap(v)} end)
  end

  @impl true
  def incr(key, by) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        INSERT INTO kv_counters (key, n, updated_at) VALUES ($1, $2, now())
        ON CONFLICT (key) DO UPDATE SET n = kv_counters.n + EXCLUDED.n, updated_at = now()
        RETURNING n
        """,
        [key, by]
      )

    n
  end

  @impl true
  def counter(key) do
    Repo.one(from c in "kv_counters", where: c.key == ^key, select: c.n) || 0
  end

  defp wrap(value) when is_map(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp wrap(value), do: %{@wrap => value}

  defp unwrap(%{@wrap => value}), do: value
  defp unwrap(value), do: value
end
