defmodule AgentManager.Models.Adapters.Anthropic do
  @moduledoc """
  Claude via the Messages API (`POST /v1/messages`).

  Differences from OpenAI that this adapter absorbs:

    * system prompts go in the top-level `system` field, not in `messages`
    * the first message must be from the user
    * current models reject sampling params (`temperature`, `top_p`), so they
      are not sent
    * there is no free-form JSON mode here; with `json: true` the adapter adds
      an instruction and callers parse tolerantly (see `AgentManager.JSON`)
    * `stop_reason: "refusal"` is surfaced as `{:error, {:refusal, details}}`
    * tools use `tool_use` / `tool_result` content blocks; the results of one
      round are sent together in a single user turn
  """

  @behaviour AgentManager.Models.ChatModel

  alias AgentManager.Models.ChatModel

  @base_url "https://api.anthropic.com/v1"
  @version "2023-06-01"
  @json_instruction "When you give your final answer, respond with a single JSON object only, with no text before or after it."

  @impl true
  def chat(messages, opts) do
    {system, conversation} = Enum.split_with(messages, &(&1.role == :system))

    system_text =
      system
      |> Enum.map(& &1.content)
      |> then(&if(opts[:json], do: &1 ++ [@json_instruction], else: &1))
      |> Enum.join("\n\n")

    body =
      %{
        model: opts[:model],
        max_tokens: opts[:max_tokens] || 16_000,
        messages: to_anthropic(conversation)
      }
      |> then(&if(system_text == "", do: &1, else: Map.put(&1, :system, system_text)))
      |> then(
        &if(opts[:tools] in [nil, []],
          do: &1,
          else: Map.put(&1, :tools, encode_tools(opts[:tools]))
        )
      )

    with {:ok, raw} <- post(body, opts) do
      case raw do
        %{"stop_reason" => "refusal"} ->
          {:error, {:refusal, raw["stop_details"]}}

        %{"content" => content} ->
          text = for %{"type" => "text", "text" => t} <- content, into: "", do: t

          calls =
            for %{"type" => "tool_use"} = block <- content,
                do: %{
                  id: block["id"],
                  name: block["name"],
                  arguments: ChatModel.decode_arguments(block["input"])
                }

          usage = raw["usage"] || %{}

          {:ok,
           %{
             content: text,
             tool_calls: calls,
             usage: ChatModel.usage(usage["input_tokens"], usage["output_tokens"]),
             model: raw["model"] || opts[:model],
             raw: raw
           }}
      end
    end
  end

  defp encode_tools(tools) do
    Enum.map(tools, &%{name: &1.name, description: &1.description, input_schema: &1.input_schema})
  end

  defp encode_message(%{role: :assistant, tool_calls: [_ | _] = calls} = m) do
    text = if m[:content] in [nil, ""], do: [], else: [%{type: "text", text: m.content}]
    uses = Enum.map(calls, &%{type: "tool_use", id: &1.id, name: &1.name, input: &1.arguments})
    %{role: "assistant", content: text ++ uses}
  end

  defp encode_message(%{role: :tool} = m) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: m.tool_call_id,
          content: m.content,
          is_error: !!m[:is_error]
        }
      ]
    }
  end

  defp encode_message(m), do: %{role: to_string(m.role), content: m.content}

  # All results of one tool round must travel in a single user turn.
  defp merge_tool_results(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn
        %{role: "user", content: [%{type: "tool_result"} | _] = blocks},
        %{role: "user", content: [%{type: "tool_result"} | _]} = acc ->
          {:cont, %{acc | content: acc.content ++ blocks}}

        msg, nil ->
          {:cont, msg}

        msg, acc ->
          {:cont, acc, msg}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  # The API needs the conversation to open with a user turn.
  defp to_anthropic(messages) do
    messages = messages |> Enum.map(&encode_message/1) |> merge_tool_results()

    case messages do
      [%{role: "assistant"} | _] ->
        [%{role: "user", content: "(conversation continues)"} | messages]

      [] ->
        [%{role: "user", content: "(empty)"}]

      _ ->
        messages
    end
  end

  defp post(body, opts) do
    [
      url: (opts[:base_url] || @base_url) <> "/messages",
      json: body,
      headers: [{"x-api-key", opts[:api_key] || ""}, {"anthropic-version", @version}],
      receive_timeout: opts[:timeout] || 60_000,
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
end
