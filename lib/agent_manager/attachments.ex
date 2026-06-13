defmodule AgentManager.Attachments do
  @moduledoc """
  Helpers for file attachments.

  Training data rows can carry an `[attachment]` column whose value is a URL
  or a data URI. The model can also emit `ANEXO(<url>)` / `ATTACHMENT(<url>)`
  in its answer to attach a file explicitly.
  """

  @data_uri ~r/data:(?<mime>[\w\/\-\.]+);(?<encoding>\w+),(?<data>[^"]*)/
  @marker ~r/(?:ANEXO|ATTACHMENT)\((?<url>https?:\/\/[^\s)]+)\)/i

  def data_uri_regex, do: @data_uri

  @doc "URLs the model asked to attach via `ANEXO(url)`."
  def extract_from_response(text),
    do: @marker |> Regex.scan(text, capture: ["url"]) |> List.flatten()

  def has_attachment?(%{segment: segment}), do: String.contains?(segment, "[attachment]")

  @doc "Value of the `[attachment]` column of a sheet-row segment, if any."
  def field(%{segment: segment}) do
    segment
    |> String.split(~r/\s\|\s(?=(?:[^"]*"[^"]*")*[^"]*$)/)
    |> Enum.find_value(fn entry ->
      case String.split(entry, ~s(: "), parts: 2) do
        [key, value] ->
          if String.contains?(key, "[attachment]"), do: String.replace(value, ~r/"\s?$/, "")

        _ ->
          nil
      end
    end)
  end

  def data_uri?(value), do: is_binary(value) and Regex.match?(@data_uri, value)

  @doc "Replaces data-URI payloads so they are never sent to a model or logged."
  def mask(text), do: Regex.replace(@data_uri, text, "data:\\1;base64,...")

  @doc "File extension for a URL, from its path or (if absent) its data-URI mime."
  def extension(url) do
    cond do
      data_uri?(url) ->
        %{"mime" => mime} = Regex.named_captures(@data_uri, url)
        mime |> MIME.extensions() |> List.first() || ""

      true ->
        url
        |> URI.parse()
        |> Map.get(:path, "")
        |> Kernel.||("")
        |> Path.extname()
        |> String.trim_leading(".")
    end
  end
end
