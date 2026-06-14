defmodule AgentManagerWeb.DebugController do
  use AgentManagerWeb, :controller

  alias AgentManager.{Bots, Conversations}
  alias AgentManager.NLP.{Language, Sentiment, Tokenizer}
  alias AgentManager.Pipeline.Context
  alias AgentManager.Pipelines.Answer.Helpers
  alias AgentManagerWeb.Params

  action_fallback AgentManagerWeb.FallbackController

  def language(conn, params) do
    with {:ok, [text]} <- Params.require(params, ["text"]) do
      opts =
        case {params["gpt"], params["bot_id"] && Bots.get(params["bot_id"])} do
          {"true", nil} -> {:error, :not_found}
          {"true", bot} -> [llm: true] ++ Helpers.classifier_opts(Context.new(%{}, bot: bot))
          _ -> []
        end

      with opts when is_list(opts) <- opts do
        code = Language.detect(text, opts)
        json(conn, [%{label: code, language: Language.codes()[code], score: 1}])
      end
    end
  end

  def sentiment(conn, params) do
    with {:ok, [text]} <- Params.require(params, ["text"]),
         {:ok, stars} <- Sentiment.stars(text) do
      json(conn, %{stars: stars, decision: stars > 2})
    end
  end

  def tokens(conn, params) do
    with {:ok, [text]} <- Params.require(params, ["text"]),
         do: json(conn, %{tokens: Tokenizer.count(text)})
  end

  @doc "The exact messages the bot would send to its model for `text` (runs the pipeline up to BuildPrompt)."
  def generate_prompt(conn, %{"id" => id} = params) do
    with {:ok, [text, user_id]} <- Params.require(params, ["text", "user_id"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, messages, ctx} <- Conversations.preview_prompt(bot, user_id, text) do
      json(conn, %{
        prompt: Enum.map(messages, &%{role: &1.role, content: &1.content}),
        trace:
          Enum.map(ctx.trace, fn {step, status, us} ->
            %{step: inspect(step), status: status, duration_us: us}
          end)
      })
    end
  end
end
