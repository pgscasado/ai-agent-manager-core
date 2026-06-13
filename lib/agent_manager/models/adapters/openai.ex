defmodule AgentManager.Models.Adapters.OpenAI do
  @moduledoc """
  OpenAI chat + embeddings. Works with any OpenAI-compatible server
  (Azure-style gateways, Groq, Together, vLLM, LM Studio) through `:base_url`.
  """

  @behaviour AgentManager.Models.ChatModel
  @behaviour AgentManager.Models.EmbeddingModel

  alias AgentManager.Models.ChatModel

  @base_url "https://api.openai.com/v1"

  @impl AgentManager.Models.ChatModel
  def chat(messages, opts) do
    body =
      %{
        model: opts[:model],
        messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content}),
        temperature: opts[:temperature],
        top_p: opts[:top_p],
        frequency_penalty: opts[:frequency_penalty],
        max_tokens: opts[:max_tokens]
      }
      |> maybe_json(opts[:json])
      |> reject_nil()

    with {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = raw} <-
           post("/chat/completions", body, opts) do
      usage = raw["usage"] || %{}

      {:ok,
       %{
         content: content || "",
         usage: ChatModel.usage(usage["prompt_tokens"], usage["completion_tokens"]),
         model: raw["model"] || opts[:model],
         raw: raw
       }}
    end
  end

  @impl AgentManager.Models.EmbeddingModel
  def embed([], _opts), do: {:ok, []}

  def embed(texts, opts) do
    with {:ok, %{"data" => data}} <-
           post("/embeddings", %{model: opts[:model], input: texts}, opts) do
      {:ok, data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])}
    end
  end

  defp maybe_json(body, true), do: Map.put(body, :response_format, %{type: "json_object"})
  defp maybe_json(body, _), do: body

  defp post(path, body, opts) do
    [
      url: (opts[:base_url] || @base_url) <> path,
      json: body,
      auth: {:bearer, opts[:api_key] || ""},
      receive_timeout: opts[:timeout] || 30_000,
      retry: :transient
    ]
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp reject_nil(map), do: Map.reject(map, fn {_, v} -> is_nil(v) end)
end
