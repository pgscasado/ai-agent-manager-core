defmodule AgentManager.NLP.Sentiment do
  @moduledoc """
  1-5 star sentiment, used to read "yes"-like replies in the attendance flow.

  Default implementation asks the utility model; swap it with

      config :agent_manager, AgentManager.NLP.Sentiment, impl: MyClassifier
  """

  @callback stars(String.t(), keyword()) :: {:ok, 1..5} | {:error, term()}

  def stars(text, opts \\ []), do: impl().stars(text, opts)

  @doc "More than 2 stars reads as agreement."
  def positive?(text, opts \\ []) do
    case stars(text, opts) do
      {:ok, n} -> n > 2
      _ -> false
    end
  end

  defp impl, do: Application.get_env(:agent_manager, __MODULE__, [])[:impl] || __MODULE__.LLM

  defmodule LLM do
    @moduledoc false
    @behaviour AgentManager.NLP.Sentiment

    @impl true
    def stars(text, opts) do
      messages = [
        %{
          role: :user,
          content:
            "Rate the sentiment of this message from 1 (very negative) to 5 (very positive). " <>
              "Answer with the digit only.\n\nMessage: #{text}"
        }
      ]

      with {:ok, %{content: content}} <-
             AgentManager.Models.chat(
               opts[:model],
               messages,
               Keyword.merge(opts[:model_opts] || [], kind: :utility)
             ),
           [digit | _] <- Regex.run(~r/[1-5]/, content) do
        {:ok, String.to_integer(digit)}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:ok, 3}
      end
    end
  end
end
