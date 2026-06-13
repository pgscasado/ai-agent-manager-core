defmodule AgentManager.NLP.Segmenter do
  @moduledoc """
  Splits source material into retrievable segments.

    * text: split on blank lines, then short paragraphs (< 80 chars) are merged
      into the previous one so headings stay attached to their content
    * sheets (list of row maps): one segment per row, `key: "value" | ...`,
      the format the attachment logic parses back
  """

  @min_paragraph 80

  def segment(rows) when is_list(rows) do
    Enum.map(rows, fn row ->
      Enum.map_join(row, " | ", fn {k, v} -> ~s(#{k}: "#{v}") end)
    end)
  end

  def segment(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n\s*\n/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce([], fn
      paragraph, [last | rest] ->
        if String.length(last) < @min_paragraph,
          do: [last <> "\n" <> paragraph | rest],
          else: [paragraph, last | rest]

      paragraph, [] ->
        [paragraph]
    end)
    |> Enum.reverse()
  end

  def segment(_), do: []
end
