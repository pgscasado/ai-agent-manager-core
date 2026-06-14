defmodule AgentManagerWeb.MessageController do
  use AgentManagerWeb, :controller

  alias AgentManager.{Bots, Conversations}
  alias AgentManagerWeb.{AnswerJSON, Params}

  action_fallback AgentManagerWeb.FallbackController

  @doc "`POST /message/:id/get_answer` - the main chat endpoint."
  def answer(conn, %{"id" => id} = params) do
    with {:ok, [text, user_id]} <- Params.require(params, ["text", "user_id"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, answer, _ctx} <- Conversations.ask(bot, user_id, String.trim(text)) do
      json(conn, AnswerJSON.render(answer))
    end
  end

  @doc "`POST /bot/:id/get_answer` - older variant that wraps the result and includes usage."
  def legacy_answer(conn, %{"id" => id} = params) do
    with {:ok, [text, user_id]} <- Params.require(params, ["text", "user_id"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, answer, ctx} <- Conversations.ask(bot, user_id, String.trim(text)) do
      json(conn, %{answer: %{result: AnswerJSON.render(answer), usage: ctx.usage}})
    end
  end

  def bot_message(conn, %{"id" => id} = params) do
    with {:ok, [text, user_id]} <- Params.require(params, ["text", "user_id"]),
         {:ok, bot} <- Bots.fetch(id),
         :ok <- Conversations.record(bot, user_id, :bot, text, List.wrap(params["flags"])) do
      json(conn, %{message: "Message inserted"})
    end
  end

  def user_message(conn, %{"id" => id} = params) do
    with {:ok, [text, user_id]} <- Params.require(params, ["text", "user_id"]),
         {:ok, bot} <- Bots.fetch(id),
         :ok <- Conversations.record(bot, user_id, :user, text) do
      json(conn, %{message: "Message inserted"})
    end
  end
end
