defmodule AgentManagerWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token check against `config :agent_manager, :api_token` (env
  `API_TOKEN`).

    * `required: false` (the bot API): enforced only when a token is
      configured, so local setups keep working without one
    * `required: true` (the admin API): refuses every request while no token
      is configured

  Brute force: after 10 failed attempts from one IP within 15 minutes, that
  IP gets 429 until the window ends, even with the right token (the socket
  shares the same counter).
  """
  import Plug.Conn

  alias AgentManager.RateLimit
  alias AgentManagerWeb.ClientIP

  @max_failures 10
  @lockout_ms :timer.minutes(15)

  def init(opts), do: Keyword.get(opts, :required, false)

  def call(conn, required?) do
    token = Application.get_env(:agent_manager, :api_token)
    ip = ClientIP.get(conn)

    cond do
      not is_binary(token) or token == "" ->
        if required?, do: deny(conn, 403, "set API_TOKEN to use this endpoint"), else: conn

      RateLimit.count(:auth_failures, ip, @lockout_ms) >= @max_failures ->
        conn
        |> put_resp_header("retry-after", to_string(RateLimit.retry_after_seconds(@lockout_ms)))
        |> deny(429, "too many failed attempts")

      valid?(token, bearer(conn)) ->
        conn

      true ->
        record_failure(ip)
        deny(conn, 401, if(bearer(conn), do: "invalid token", else: "missing bearer token"))
    end
  end

  @doc "Token check for other entry points (the socket), with the same lockout."
  def check(given, ip) do
    token = Application.get_env(:agent_manager, :api_token)

    cond do
      not is_binary(token) or token == "" -> :ok
      RateLimit.count(:auth_failures, ip, @lockout_ms) >= @max_failures -> :error
      valid?(token, given) -> :ok
      true -> record_failure(ip) && :error
    end
  end

  defp valid?(token, given), do: is_binary(given) and Plug.Crypto.secure_compare(token, given)

  defp record_failure(ip), do: RateLimit.hit(:auth_failures, ip, @max_failures, @lockout_ms)

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

defmodule AgentManagerWeb.Plugs.RateLimit do
  @moduledoc """
  Per-IP request limit for a group of routes:

      plug AgentManagerWeb.Plugs.RateLimit, bucket: :api, limit: 120, window_ms: 60_000

  Limits can be overridden in config, per bucket:

      config :agent_manager, AgentManagerWeb.Plugs.RateLimit, api: {300, 60_000}
  """
  import Plug.Conn

  alias AgentManager.RateLimit
  alias AgentManagerWeb.ClientIP

  def init(opts), do: {opts[:bucket], {opts[:limit], opts[:window_ms] || 60_000}}

  def call(conn, {bucket, default}) do
    {limit, window_ms} =
      Application.get_env(:agent_manager, __MODULE__, [])[bucket] || default

    case RateLimit.hit(bucket, ClientIP.get(conn), limit, window_ms) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate limited"}))
        |> halt()
    end
  end
end

defmodule AgentManagerWeb.ClientIP do
  @moduledoc """
  The client's IP. Behind a reverse proxy every request comes from the proxy,
  so `X-Forwarded-For` is used - but only when the request comes from a
  trusted proxy (`TRUSTED_PROXIES`, e.g. `127.0.0.1,::1`), since anyone can
  send that header. The address used is the last one not added by a trusted
  proxy, which a client can't forge.
  """

  def get(%Plug.Conn{} = conn),
    do: resolve(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))

  @doc "Same, from a socket's `connect_info` (`peer_data` + `x_headers`)."
  def from_connect_info(%{peer_data: %{address: address}} = info) do
    forwarded = for {"x-forwarded-for", value} <- info[:x_headers] || [], do: value
    resolve(address, forwarded)
  end

  def from_connect_info(_info), do: "unknown"

  defp resolve(remote_ip, forwarded) do
    remote = :inet.ntoa(remote_ip) |> to_string()
    trusted = Application.get_env(:agent_manager, :trusted_proxies, [])

    if remote in trusted do
      forwarded
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find(remote, &(&1 not in trusted and valid_ip?(&1)))
    else
      remote
    end
  end

  defp valid_ip?(ip), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(ip)))
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
