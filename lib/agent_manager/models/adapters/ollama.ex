defmodule AgentManager.Models.Adapters.Ollama do
  @moduledoc "Local models served by Ollama (`/api/chat`, `/api/embed`)."

  @behaviour AgentManager.Models.ChatModel
  @behaviour AgentManager.Models.EmbeddingModel

  alias AgentManager.Models.ChatModel

  @base_url "http://localhost:11434"

  @impl AgentManager.Models.ChatModel
  def chat(messages, opts) do
    body =
      %{
        model: opts[:model],
        stream: false,
        messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content}),
        options:
          Map.reject(
            %{temperature: opts[:temperature], top_p: opts[:top_p]},
            &is_nil(elem(&1, 1))
          )
      }
      |> then(&if(opts[:json], do: Map.put(&1, :format, "json"), else: &1))

    with {:ok, %{"message" => %{"content" => content}} = raw} <- post("/api/chat", body, opts) do
      {:ok,
       %{
         content: content,
         usage: ChatModel.usage(raw["prompt_eval_count"], raw["eval_count"]),
         model: opts[:model],
         raw: raw
       }}
    end
  end

  @impl AgentManager.Models.EmbeddingModel
  def embed([], _opts), do: {:ok, []}

  def embed(texts, opts) do
    with {:ok, %{"embeddings" => vectors}} <-
           post("/api/embed", %{model: opts[:model], input: texts}, opts) do
      {:ok, vectors}
    end
  end

  defp post(path, body, opts) do
    [
      url: (opts[:base_url] || @base_url) <> path,
      json: body,
      receive_timeout: opts[:timeout] || 120_000
    ]
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end
end
