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
  """

  @behaviour AgentManager.Models.ChatModel

  alias AgentManager.Models.ChatModel

  @base_url "https://api.anthropic.com/v1"
  @version "2023-06-01"
  @json_instruction "Respond with a single JSON object only, with no text before or after it."

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

    with {:ok, raw} <- post(body, opts) do
      case raw do
        %{"stop_reason" => "refusal"} ->
          {:error, {:refusal, raw["stop_details"]}}

        %{"content" => content} ->
          text = for %{"type" => "text", "text" => t} <- content, into: "", do: t
          usage = raw["usage"] || %{}

          {:ok,
           %{
             content: text,
             usage: ChatModel.usage(usage["input_tokens"], usage["output_tokens"]),
             model: raw["model"] || opts[:model],
             raw: raw
           }}
      end
    end
  end

  # The API needs the conversation to open with a user turn.
  defp to_anthropic(messages) do
    messages = Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})

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
