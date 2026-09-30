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
        messages: Enum.map(messages, &encode_message/1),
        temperature: opts[:temperature],
        top_p: opts[:top_p],
        frequency_penalty: opts[:frequency_penalty],
        max_tokens: opts[:max_tokens],
        tools: encode_tools(opts[:tools])
      }
      |> maybe_json(opts[:json])
      |> reject_nil()
      # provider-specific fields, e.g. `extra_body: %{reasoning_effort: "none"}`
      |> Map.merge(opts[:extra_body] || %{})

    with {:ok, %{"choices" => [%{"message" => message} | _]} = raw} <-
           post("/chat/completions", body, opts) do
      usage = raw["usage"] || %{}

      {:ok,
       %{
         content: message["content"] || "",
         tool_calls: Enum.map(message["tool_calls"] || [], &decode_tool_call/1),
         usage: ChatModel.usage(usage["prompt_tokens"], usage["completion_tokens"]),
         model: raw["model"] || opts[:model],
         raw: raw
       }}
    end
  end

  defp encode_message(%{role: :assistant, tool_calls: [_ | _] = calls} = m) do
    %{
      role: "assistant",
      content: m[:content],
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: Jason.encode!(call.arguments)}
          }
        end)
    }
  end

  defp encode_message(%{role: :tool} = m),
    do: %{role: "tool", tool_call_id: m.tool_call_id, content: m.content}

  defp encode_message(m), do: %{role: to_string(m.role), content: m.content}

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{name: tool.name, description: tool.description, parameters: tool.input_schema}
      }
    end)
  end

  defp decode_tool_call(%{"id" => id, "function" => function}) do
    %{
      id: id,
      name: function["name"],
      arguments: ChatModel.decode_arguments(function["arguments"])
    }
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
