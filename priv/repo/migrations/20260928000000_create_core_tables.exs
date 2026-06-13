defmodule AgentManager.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:bots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identifier, :string, null: false
      add :name, :string, null: false, default: "New Bot"
      add :access_control, :boolean, null: false, default: false
      add :access_control_message, :text
      add :user_history_time, :integer, null: false, default: 0
      add :gpt_language_detector, :boolean, null: false, default: false
      add :has_attendance, :boolean, null: false, default: true
      add :attendance_on_greeting, :boolean, null: false, default: true
      add :direct_attendance, :boolean, null: false, default: false
      add :token_limit, :integer, null: false, default: 3500
      add :total_tokens, :bigint, null: false, default: 0
      add :text_search, :boolean, null: false, default: false
      add :disabled, :boolean, null: false, default: false
      add :start_message, :text
      add :model_config, :map
      add :training_info, :map
      add :job_timings, :map
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bots, [:identifier])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, references(:bots, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :string, null: false
      add :message, :text
      add :response, :map
      add :is_response, :boolean, null: false, default: false
      add :flags, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:bot_id, :user_id, :inserted_at])

    create table(:llm_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, :binary_id
      add :correlation_id, :string
      add :model, :string, null: false
      add :prompt_tokens, :integer, null: false, default: 0
      add :completion_tokens, :integer, null: false, default: 0
      add :total_tokens, :integer, null: false, default: 0
      add :key_hint, :string
      add :latency_ms, :integer
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:llm_calls, [:bot_id, :inserted_at])

    # Dimension-less vector column: bots may use embedding models of different
    # sizes. Searches always filter by bot + model, and the per-model partial
    # HNSW indexes (see README) are created once a model's dimension is known.
    create table(:segments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, references(:bots, type: :binary_id, on_delete: :delete_all), null: false
      add :segment, :text, null: false
      add :cleaned_segment, :text
      add :embedding, :vector, null: false
      add :embedding_model, :string, null: false
      add :index, :integer
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:segments, [:bot_id, :embedding_model])
  end

  def down do
    drop table(:segments)
    drop table(:llm_calls)
    drop table(:messages)
    drop table(:bots)
  end
end
