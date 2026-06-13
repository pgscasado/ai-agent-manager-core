defmodule AgentManager.JSON do
  @moduledoc """
  Tolerant decoding of model output that is *supposed* to be a JSON object.

  Order of attempts:

    1. strict decode
    2. the outermost `{...}` inside the text (models that add prose or fences)
    3. syntactic repair of truncated output: closes the dangling string/key
       and the object
  """

  @spec decode_object(String.t()) :: {:ok, map()} | {:error, :invalid_json}
  def decode_object(text) when is_binary(text) do
    text = String.trim(text)

    with :error <- strict(text),
         :error <- strict(extract(text)),
         :error <- strict(repair(text)) do
      {:error, :invalid_json}
    end
  end

  def decode_object(_), do: {:error, :invalid_json}

  defp strict(nil), do: :error

  defp strict(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp extract(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> nil
    end
  end

  @doc false
  def repair(text) do
    fixed =
      if String.starts_with?(text, "{\""),
        do: text,
        else: ~s({") <> String.trim_leading(text, "{")

    fixed = String.trim_trailing(fixed, "\\")

    fixed =
      if Regex.match?(~r/,\s?"[a-zA-Z]+(_[a-zA-Z]+)*_?"?$/, fixed) do
        if(String.ends_with?(fixed, "\""), do: fixed, else: fixed <> "\"") <> ":"
      else
        fixed
      end

    fixed = if String.ends_with?(fixed, ":"), do: fixed <> "null", else: fixed

    cond do
      String.ends_with?(fixed, "\"}") or String.ends_with?(fixed, "}") ->
        fixed

      String.ends_with?(fixed, "null") or String.ends_with?(fixed, "\"") ->
        fixed <> "}"

      true ->
        fixed <> "\"}"
    end
  end
end
