# Terminal chat with a bot on a running server (talks HTTP, like any client).
#
#   mix run --no-start scripts/chat.exs <bot id or identifier> [user_id] [base_url]
#
# Lines starting with "/" are commands: /quit, /user <id> (switch user).
# Each reply shows the flags the API returned (attendance, tools used, errors).

Application.ensure_all_started(:req)

{bot, user, base} =
  case System.argv() do
    [bot] -> {bot, "terminal-user", "http://localhost:4000"}
    [bot, user] -> {bot, user, "http://localhost:4000"}
    [bot, user, base | _] -> {bot, user, base}
    [] -> IO.puts("usage: mix run --no-start scripts/chat.exs <bot> [user_id] [base_url]") && System.halt(1)
  end

defmodule Chat do
  def loop(bot, user, base) do
    case IO.gets("#{user}> ") do
      :eof ->
        :ok

      line ->
        case String.trim(line) do
          "" -> loop(bot, user, base)
          "/quit" -> :ok
          "/user " <> new_user -> loop(bot, String.trim(new_user), base)
          text -> send_message(bot, user, base, text) && loop(bot, user, base)
        end
    end
  end

  defp send_message(bot, user, base, text) do
    case Req.post("#{base}/message/#{bot}/get_answer", json: %{text: text, user_id: user}, receive_timeout: 180_000) do
      {:ok, %{status: 200, body: body}} ->
        IO.puts("bot> " <> body["response"])

        flags =
          [
            body["start_attendance"] == "true" && "handoff to human",
            body["asked_for_attendance"] == "true" && "offered a human",
            body["error"] && "error",
            (tools = get_in(body, ["metadata", "tools_used"])) && "tools: #{Enum.join(tools, ", ")}",
            body["attachments"] && "attachments: #{inspect(body["attachments"])}"
          ]
          |> Enum.filter(& &1)

        if flags != [], do: IO.puts("     (" <> Enum.join(flags, "; ") <> ")")

      {:ok, %{status: status, body: body}} ->
        IO.puts("!! HTTP #{status}: #{inspect(body)}")

      {:error, e} ->
        IO.puts("!! #{Exception.message(e)} - is the server running at #{base}?")
    end

    true
  end
end

IO.puts("Chatting with #{bot} at #{base} as #{user}. /quit to exit, /user <id> to switch user.")
Chat.loop(bot, user, base)
