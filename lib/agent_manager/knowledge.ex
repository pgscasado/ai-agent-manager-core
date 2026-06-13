defmodule AgentManager.Knowledge do
  @moduledoc "Retrieval over a bot's trained segments."

  alias AgentManager.{Bots, Models, VectorStore}
  alias AgentManager.NLP.Text

  @doc "Top-`k` segments for `text`, most similar first."
  def search(bot, text, k, opts \\ []) do
    spec = Bots.embedding_model(bot)
    query = text |> Text.remove_stopwords() |> String.downcase()

    with {:ok, [embedding]} <- Models.embed(spec, [query], opts) do
      {:ok, VectorStore.impl().search(bot.id, embedding, spec, k)}
    end
  end

  def count(bot), do: VectorStore.impl().count(bot.id)
end
