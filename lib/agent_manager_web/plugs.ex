defmodule AgentManagerWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token check against `config :agent_manager, :api_token` (env
  `API_TOKEN`).

    * `required: false` (the bot API): enforced only when a token is
      configured, so local setups keep working without one
    * `required: true` (the admin API): refuses every request while no token
      is configured
  """
  import Plug.Conn

  def init(opts), do: Keyword.get(opts, :required, false)

  def call(conn, required?) do
    case {Application.get_env(:agent_manager, :api_token), bearer(conn)} do
      {token, given} when is_binary(token) and token != "" and is_binary(given) ->
        if Plug.Crypto.secure_compare(token, given),
          do: conn,
          else: deny(conn, 401, "invalid token")

      {token, _} when is_binary(token) and token != "" ->
        deny(conn, 401, "missing bearer token")

      _ when required? ->
        deny(conn, 403, "set API_TOKEN to use this endpoint")

      _ ->
        conn
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end

defmodule AgentManagerWeb.Plugs.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw body of webhook requests in
  `conn.assigns.raw_body`, so their signatures can be checked after parsing.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        conn =
          if String.starts_with?(conn.request_path, "/whatsapp"),
            do: Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body),
            else: conn

        {status, body, conn}

      other ->
        other
    end
  end
end
