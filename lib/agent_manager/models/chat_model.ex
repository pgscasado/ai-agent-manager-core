defmodule AgentManager.Models.ChatModel do
  @moduledoc """
  Behaviour for chat-completion providers, and the provider-neutral message
  format every adapter translates to and from.

  ## Messages

      %{role: :system | :user, content: String.t()}
      %{role: :assistant, content: String.t()}
      %{role: :assistant, content: String.t(), tool_calls: [tool_call()]}   # model asked for tools
      %{role: :tool, tool_call_id: String.t(), name: String.t(), content: String.t(), is_error: boolean()}

  ## Tools

  `opts[:tools]` is a list of `%{name, description, input_schema}` (JSON Schema).
  When the model wants tools, the response has a non-empty `tool_calls` list
  of `%{id, name, arguments}` (arguments already decoded to a map).

  ## Common opts (adapters ignore what they don't support)

    * `:model` - provider-side model name (e.g. `"gpt-4o"`, `"claude-opus-5"`)
    * `:api_key`, `:base_url`, `:req_options`
    * `:temperature`, `:top_p`, `:frequency_penalty`, `:max_tokens`
    * `:json` - `true` when the caller expects a JSON object as the final answer
    * `:tools` - tool definitions, see above
    * `:timeout` - receive timeout in ms
  """

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type tool :: %{name: String.t(), description: String.t(), input_schema: map()}
  @type message :: %{required(:role) => atom(), optional(atom()) => term()}
  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
  @type response :: %{
          content: String.t(),
          tool_calls: [tool_call()],
          usage: usage(),
          model: String.t(),
          raw: term()
        }

  @callback chat([message()], keyword()) :: {:ok, response()} | {:error, term()}

  @doc "Builds a usage map, filling in the total."
  def usage(prompt, completion) do
    prompt = prompt || 0
    completion = completion || 0
    %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion}
  end

  @doc "Decodes tool-call arguments that arrive as a JSON string; never raises."
  def decode_arguments(args) when is_map(args), do: args
  def decode_arguments(nil), do: %{}
  def decode_arguments(""), do: %{}

  def decode_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => json}
    end
  end
end

defmodule AgentManager.Models.EmbeddingModel do
  @moduledoc "Behaviour for embedding providers. Vectors come back in input order."

  @callback embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
end
