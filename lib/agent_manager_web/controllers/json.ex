defmodule AgentManagerWeb.BotJSON do
  @moduledoc "Bot rendering. API keys are never returned, only a hint per provider."

  alias AgentManager.Bots.Bot

  def show(%Bot{} = bot) do
    bot
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.update!(:model_config, &model_config/1)
    |> Map.update!(:training_info, &embed/1)
    |> Map.update!(:job_timings, &embed/1)
  end

  defp model_config(nil), do: nil

  defp model_config(config) do
    config
    |> Map.from_struct()
    |> Map.update!(:api_keys, fn keys ->
      Map.new(keys || %{}, fn {provider, key} -> {provider, hint(key)} end)
    end)
    |> Map.update!(:content, &embed/1)
  end

  defp embed(nil), do: nil
  defp embed(%DateTime{} = dt), do: dt

  defp embed(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.new(fn {k, v} -> {k, embed(v)} end)

  defp embed(other), do: other

  defp hint(key) when is_binary(key) and byte_size(key) > 10,
    do: String.slice(key, 0, 5) <> "..." <> String.slice(key, -4, 4)

  defp hint(_), do: "***"
end

defmodule AgentManagerWeb.AnswerJSON do
  @moduledoc """
  Renders an `%Answer{}` in the 1.0 API shape: booleans as `"true"`/`"false"`
  strings and `metadata` values likewise.
  """

  alias AgentManager.Answer

  def render(%Answer{} = a, usage \\ nil) do
    base = %{
      type: to_string(a.type),
      response: a.response,
      start_attendance: s(a.start_attendance),
      asked_for_attendance: s(a.asked_for_attendance),
      metadata: Map.new(a.metadata, fn {k, v} -> {k, s(v)} end)
    }

    base = if a.type == :attachment, do: Map.put(base, :attachments, a.attachments), else: base
    base = if a.error, do: Map.put(base, :error, true), else: base
    if usage, do: Map.put(base, :usage, usage), else: base
  end

  defp s(v) when is_boolean(v), do: to_string(v)
  defp s(v), do: v
end
