defmodule AgentManager.NLP.Tokenizer do
  @moduledoc """
  Token counting, used to fit retrieved context into a model's budget.

  The implementation is swappable:

      config :agent_manager, AgentManager.NLP.Tokenizer, impl: MyApp.TiktokenCounter

  The default is a character-ratio estimate (~3.5 chars/token, a good fit for
  cl100k/o200k on Portuguese and English text). It is intentionally
  conservative: over-counting only means slightly less context is sent.
  """

  @callback count(String.t()) :: non_neg_integer()

  def count(nil), do: 0
  def count(text) when is_binary(text), do: impl().count(text)

  def count_messages(messages), do: messages |> Enum.map(&(count(&1.content) + 4)) |> Enum.sum()

  defp impl, do: Application.get_env(:agent_manager, __MODULE__, [])[:impl] || __MODULE__.Approx

  defmodule Approx do
    @moduledoc false
    @behaviour AgentManager.NLP.Tokenizer
    @impl true
    def count(text), do: ceil(String.length(text) / 3.5)
  end
end
