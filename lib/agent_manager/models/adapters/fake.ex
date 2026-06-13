defmodule AgentManager.Models.Adapters.Fake do
  @moduledoc """
  Deterministic, offline provider for tests and local development.

  **Chat**: by default answers every JSON request with a well-formed answer
  echoing the last user message. Script it with a responder:

      Fake.set_responder(fn messages, opts -> {:ok, ~s({"response": "hi"})} end)

  The responder is global (stored in `:persistent_term`), because pipeline
  steps run in other processes than the test; tests that set it must be
  `async: false` and call `Fake.reset/0`.

  **Embeddings**: hashed bag-of-words vectors (64 dims, L2-normalised), so
  texts sharing words are close under cosine similarity - enough for
  retrieval to behave sensibly without a real model.
  """

  @behaviour AgentManager.Models.ChatModel
  @behaviour AgentManager.Models.EmbeddingModel

  alias AgentManager.Models.ChatModel

  @dims 64
  @key {__MODULE__, :responder}

  def set_responder(fun) when is_function(fun, 2), do: :persistent_term.put(@key, fun)
  def reset, do: :persistent_term.erase(@key)

  @impl AgentManager.Models.ChatModel
  def chat(messages, opts) do
    responder = :persistent_term.get(@key, &default_responder/2)

    case responder.(messages, opts) do
      {:ok, content} ->
        prompt_tokens = messages |> Enum.map(&String.length(&1.content)) |> Enum.sum() |> div(4)

        {:ok,
         %{
           content: content,
           usage: ChatModel.usage(prompt_tokens, div(String.length(content), 4)),
           model: opts[:model],
           raw: nil
         }}

      {:error, _} = error ->
        error
    end
  end

  defp default_responder(messages, opts) do
    last_user = messages |> Enum.reverse() |> Enum.find(%{content: ""}, &(&1.role == :user))

    if opts[:json] do
      {:ok,
       Jason.encode!(%{
         response: "Echo: " <> last_user.content,
         offer_human_attendance: "false",
         start_attendance: "false",
         missing_info: "false",
         yes_or_no_question: "false",
         response_language: "pt",
         is_greeting_response: "false"
       })}
    else
      {:ok, last_user.content}
    end
  end

  @impl AgentManager.Models.EmbeddingModel
  def embed(texts, _opts), do: {:ok, Enum.map(texts, &vector/1)}

  def vector(text) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.reduce(List.duplicate(0.0, @dims), fn word, acc ->
        List.update_at(acc, :erlang.phash2(word, @dims), &(&1 + 1.0))
      end)

    norm = :math.sqrt(Enum.reduce(counts, 0.0, &(&1 * &1 + &2)))
    if norm == 0.0, do: counts, else: Enum.map(counts, &(&1 / norm))
  end
end
