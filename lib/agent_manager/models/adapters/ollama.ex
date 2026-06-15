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
        messages: Enum.map(messages, &encode_message/1),
        options:
          Map.reject(
            %{temperature: opts[:temperature], top_p: opts[:top_p]},
            &is_nil(elem(&1, 1))
          )
      }
      |> then(&if(opts[:json], do: Map.put(&1, :format, "json"), else: &1))
      |> then(
        &if(opts[:tools] in [nil, []],
          do: &1,
          else: Map.put(&1, :tools, encode_tools(opts[:tools]))
        )
      )

    with {:ok, %{"message" => message} = raw} <- post("/api/chat", body, opts) do
      {:ok,
       %{
         content: message["content"] || "",
         # Ollama does not id its tool calls; ids only need to be unique per turn.
         tool_calls:
           (message["tool_calls"] || [])
           |> Enum.with_index()
           |> Enum.map(fn {%{"function" => f}, i} ->
             %{
               id: "call_#{i}",
               name: f["name"],
               arguments: ChatModel.decode_arguments(f["arguments"])
             }
           end),
         usage: ChatModel.usage(raw["prompt_eval_count"], raw["eval_count"]),
         model: opts[:model],
         raw: raw
       }}
    end
  end

  defp encode_message(%{role: :assistant, tool_calls: [_ | _] = calls} = m) do
    %{
      role: "assistant",
      content: m[:content] || "",
      tool_calls: Enum.map(calls, &%{function: %{name: &1.name, arguments: &1.arguments}})
    }
  end

  defp encode_message(%{role: :tool} = m),
    do: %{role: "tool", content: m.content, tool_name: m.name}

  defp encode_message(m), do: %{role: to_string(m.role), content: m.content}

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{name: tool.name, description: tool.description, parameters: tool.input_schema}
      }
    end)
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
