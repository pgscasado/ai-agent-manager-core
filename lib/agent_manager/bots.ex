defmodule AgentManager.Bots do
  @moduledoc "Bot management. Every write publishes a `bot.*` event."

  alias AgentManager.{Events, Store}
  alias AgentManager.Bots.Bot

  defp store, do: Store.impl()

  def get(id_or_identifier) when is_binary(id_or_identifier),
    do: store().get_bot(id_or_identifier)

  def get(_), do: nil

  def fetch(id) do
    case get(id) do
      nil -> {:error, :not_found}
      bot -> {:ok, bot}
    end
  end

  def list(cursor, size), do: store().list_bots(cursor, size)

  def get_many(ids), do: store().get_bots(ids)

  def create(params) do
    %Bot{}
    |> Bot.changeset(normalize_params(params))
    |> store().insert_bot()
    |> tap_event("bot.created")
  end

  def update(%Bot{} = bot, params) do
    bot
    |> Bot.changeset(normalize_params(params))
    |> store().update_bot()
    |> tap_event("bot.updated")
  end

  def delete(%Bot{} = bot) do
    AgentManager.VectorStore.impl().delete_all(bot.id)
    bot |> store().delete_bot() |> tap_event("bot.deleted")
  end

  @doc "Sets one top-level flag from a path value, with the 1.0 API coercions."
  def patch_field(%Bot{} = bot, field, value, extra \\ %{}) when is_atom(field) do
    if field in Bot.patchable_fields() do
      update(bot, Map.merge(extra, %{to_string(field) => coerce(field, value)}))
    else
      {:error, :forbidden_field}
    end
  end

  @doc "Sets one `model_config` field (`llm_model`, `temperature`, `api_key`...)."
  def patch_model_field(%Bot{model_config: nil}, _field, _value), do: {:error, :not_configured}

  def patch_model_field(%Bot{} = bot, field, value) do
    config = Map.from_struct(bot.model_config) |> Map.drop([:content])

    config =
      case field do
        :temperature ->
          %{config | temperature: to_float(value)}

        :llm_model ->
          %{config | llm_model: value}

        :utility_model ->
          %{config | utility_model: value}

        :embedding_model ->
          %{config | embedding_model: value}

        {:api_key, provider} ->
          %{config | api_keys: Map.put(config.api_keys || %{}, provider, value)}
      end

    update(bot, %{"model_config" => config})
  end

  def set_job_timings(%Bot{} = bot, inactive, nps) do
    update(bot, %{"job_timings" => %{"inactive_minutes" => inactive, "nps_minutes" => nps}})
  end

  def set_training_info(%Bot{} = bot, info), do: update(bot, %{"training_info" => info})

  def add_tokens(bot_id, tokens), do: store().add_bot_tokens(bot_id, tokens)

  @doc "The bot's chat model spec (nil means the configured default)."
  def chat_model(%Bot{model_config: %{llm_model: spec}}), do: spec
  def chat_model(_), do: nil

  def utility_model(%Bot{model_config: %{utility_model: spec}}) when spec not in [nil, ""],
    do: spec

  def utility_model(bot), do: chat_model(bot)

  def embedding_model(%Bot{model_config: %{embedding_model: spec}}),
    do: AgentManager.Models.embedding_spec(spec)

  def embedding_model(_), do: AgentManager.Models.embedding_spec(nil)

  def content(%Bot{model_config: %{content: %{} = content}}), do: content
  def content(_), do: %Bot.Content{}

  def allowed_languages(bot) do
    case content(bot).language do
      %{allowed_languages: langs} when is_list(langs) -> langs
      _ -> []
    end
  end

  # -- param normalisation ---------------------------------------------------

  @doc """
  Accepts the 1.0 API payload shape: `openai_config` / `temp_content` /
  `openai_key` become `model_config` / `content` / `api_keys.openai`.
  """
  def normalize_params(params) do
    params = stringify(params)

    case Map.pop(params, "openai_config") do
      {nil, params} ->
        Map.update(params, "model_config", nil, &normalize_config/1) |> drop_nil("model_config")

      {config, params} ->
        Map.put(params, "model_config", normalize_config(config))
    end
  end

  defp normalize_config(nil), do: nil

  defp normalize_config(config) do
    {legacy_key, config} = Map.pop(config, "openai_key")
    {temp, config} = Map.pop(config, "temp_content")

    config
    |> then(&if(temp, do: Map.put_new(&1, "content", temp), else: &1))
    |> then(fn c ->
      if legacy_key in [nil, ""],
        do: c,
        else:
          Map.update(
            c,
            "api_keys",
            %{"openai" => legacy_key},
            &Map.put_new(&1, "openai", legacy_key)
          )
    end)
  end

  defp drop_nil(map, key), do: if(is_nil(map[key]), do: Map.delete(map, key), else: map)

  defp stringify(%_{} = struct), do: struct

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  # -- coercions for the PATCH /bot/:id/<field>/:value endpoints ---------------

  defp coerce(:start_message, value) when value in [":unset", "", nil], do: nil
  defp coerce(:start_message, value), do: value
  defp coerce(:user_history_time, value), do: to_int(value)
  defp coerce(_boolean, value), do: parse_boolean(value)

  def parse_boolean(value) do
    String.downcase(to_string(value)) not in ~w(undefined null nan false no f n 0 off) and
      to_string(value) != ""
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_float(v) when is_number(v), do: v / 1

  defp to_float(v) do
    case Float.parse(to_string(v)) do
      {f, _} -> f
      :error -> 0.4
    end
  end

  defp tap_event({:ok, bot} = ok, type) do
    Events.publish(type, %{bot_id: bot.id, identifier: bot.identifier}, bot_id: bot.id)
    ok
  end

  defp tap_event(error, _type), do: error
end
