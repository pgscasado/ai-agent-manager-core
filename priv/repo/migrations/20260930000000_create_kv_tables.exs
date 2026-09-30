defmodule AgentManager.Repo.Migrations.CreateKvTables do
  use Ecto.Migration

  def change do
    create table(:kv_entries, primary_key: false) do
      add :scope, :string, null: false, primary_key: true
      add :key, :string, null: false, primary_key: true
      add :value, :map, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:kv_counters, primary_key: false) do
      add :key, :string, null: false, primary_key: true
      add :n, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
