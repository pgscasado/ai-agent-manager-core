defmodule AgentManager.Models.ChatModel do
  @moduledoc """
  Behaviour for chat-completion providers.

  Messages are plain maps: `%{role: :system | :user | :assistant, content: String.t()}`.

  Common opts every adapter receives (adapters ignore what they don't support):

    * `:model` - provider-side model name (e.g. `"gpt-4o"`, `"claude-opus-5"`)
    * `:api_key`, `:base_url`
    * `:temperature`, `:top_p`, `:frequency_penalty`, `:max_tokens`
    * `:json` - `true` when the caller expects a JSON object back
    * `:timeout` - receive timeout in ms
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t()}
  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
  @type response :: %{content: String.t(), usage: usage(), model: String.t(), raw: term()}

  @callback chat([message()], keyword()) :: {:ok, response()} | {:error, term()}

  @doc "Builds a usage map, filling in the total."
  def usage(prompt, completion) do
    prompt = prompt || 0
    completion = completion || 0
    %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion}
  end
end

defmodule AgentManager.Models.EmbeddingModel do
  @moduledoc "Behaviour for embedding providers. Vectors come back in input order."

  @callback embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
end
