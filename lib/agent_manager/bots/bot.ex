defmodule AgentManager.Bots.Bot.Language do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder
  embedded_schema do
    field :allowed_languages, {:array, :string}, default: []
    field :default_language, :string
  end

  def changeset(lang, attrs), do: cast(lang, attrs, [:allowed_languages, :default_language])
end

defmodule AgentManager.Bots.Bot.Content do
  @moduledoc "The knowledge a bot is trained on plus its behavioural rules."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder
  embedded_schema do
    field :bot_name, :string
    field :source_text, :string, default: ""
    field :source_urls, {:array, :string}, default: []
    field :source_files, {:array, :string}, default: []
    field :behavioral_rules, :string
    field :topics, {:array, :string}, default: []
    embeds_one :language, AgentManager.Bots.Bot.Language, on_replace: :update
  end

  def changeset(content, attrs) do
    content
    |> cast(attrs, [
      :bot_name,
      :source_text,
      :source_urls,
      :source_files,
      :behavioral_rules,
      :topics
    ])
    |> cast_embed(:language)
  end
end

defmodule AgentManager.Bots.Bot.ModelConfig do
  @moduledoc """
  Which models a bot uses. Every model field takes a spec such as
  `"openai:gpt-4o"` or `"anthropic:claude-opus-5"`; `nil` means the
  configured default (see `AgentManager.Models`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :llm_model, :string
    field :utility_model, :string
    field :embedding_model, :string
    field :temperature, :float, default: 0.4
    field :message_buffer, :integer, default: 5
    field :api_keys, :map, default: %{}, redact: true
    embeds_one :content, AgentManager.Bots.Bot.Content, on_replace: :update
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :llm_model,
      :utility_model,
      :embedding_model,
      :temperature,
      :message_buffer,
      :api_keys
    ])
    |> validate_number(:temperature, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> cast_embed(:content)
    |> then(
      &if(get_field(&1, :content),
        do: &1,
        else: put_embed(&1, :content, %AgentManager.Bots.Bot.Content{})
      )
    )
  end
end

defmodule AgentManager.Bots.Bot.TrainingInfo do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder
  embedded_schema do
    field :status, Ecto.Enum, values: [:ON_TRAINING, :FINISHED, :ERROR]
    field :error_messages, {:array, :string}, default: []
    field :data_json, :map, default: %{}
    field :duration, :integer, default: 0
    field :timestamp, :utc_datetime_usec
  end

  def changeset(info, attrs) do
    info
    |> cast(attrs, [:status, :error_messages, :data_json, :duration, :timestamp])
    |> then(
      &if(get_field(&1, :timestamp), do: &1, else: put_change(&1, :timestamp, DateTime.utc_now()))
    )
  end
end

defmodule AgentManager.Bots.Bot.JobTimings do
  @moduledoc "Minutes of user silence before `conversation.inactive` / `conversation.nps_due` fire."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder
  embedded_schema do
    field :inactive_minutes, :integer
    field :nps_minutes, :integer
  end

  def changeset(timings, attrs), do: cast(timings, attrs, [:inactive_minutes, :nps_minutes])
end

defmodule AgentManager.Bots.Bot do
  @moduledoc "A configured agent: behaviour flags, model selection and knowledge settings."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "bots" do
    field :identifier, :string
    field :name, :string, default: "New Bot"
    field :access_control, :boolean, default: false
    field :access_control_message, :string
    field :user_history_time, :integer, default: 0
    field :gpt_language_detector, :boolean, default: false
    field :has_attendance, :boolean, default: true
    field :attendance_on_greeting, :boolean, default: true
    field :direct_attendance, :boolean, default: false
    field :token_limit, :integer, default: 3500
    field :total_tokens, :integer, default: 0
    field :text_search, :boolean, default: false
    field :disabled, :boolean, default: false
    field :start_message, :string

    embeds_one :model_config, __MODULE__.ModelConfig, on_replace: :update
    embeds_one :training_info, __MODULE__.TrainingInfo, on_replace: :update
    embeds_one :job_timings, __MODULE__.JobTimings, on_replace: :update

    timestamps()
  end

  @fields ~w(identifier name access_control access_control_message user_history_time gpt_language_detector
             has_attendance attendance_on_greeting direct_attendance token_limit text_search disabled start_message)a

  @doc "Fields that `PATCH /bot/:id/<field>/:value` may change."
  def patchable_fields,
    do: ~w(attendance_on_greeting direct_attendance has_attendance text_search user_history_time
           access_control disabled gpt_language_detector start_message)a

  def changeset(bot, attrs) do
    bot
    |> cast(attrs, @fields)
    |> cast_embed(:model_config)
    |> cast_embed(:training_info)
    |> cast_embed(:job_timings)
    |> put_identifier()
    |> validate_number(:user_history_time, greater_than_or_equal_to: 0)
    |> unique_constraint(:identifier)
  end

  defp put_identifier(changeset) do
    if get_field(changeset, :identifier),
      do: changeset,
      else: put_change(changeset, :identifier, Ecto.UUID.generate())
  end
end
