import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/agent_manager start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :agent_manager, AgentManagerWeb.Endpoint, server: true
end

config :agent_manager, AgentManagerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Default models can be chosen per deployment, e.g. a Gemini-only setup:
#   DEFAULT_CHAT_MODEL=gemini:gemini-3.8-flash DEFAULT_EMBEDDING_MODEL=gemini:gemini-embedding-001
# (bots that set their own models are unaffected).
model_defaults =
  for {key, var} <- [
        chat: "DEFAULT_CHAT_MODEL",
        utility: "DEFAULT_UTILITY_MODEL",
        embedding: "DEFAULT_EMBEDDING_MODEL"
      ],
      value = System.get_env(var),
      value not in [nil, ""],
      do: {key, value}

if model_defaults != [] do
  config :agent_manager, AgentManager.Models, defaults: model_defaults
end

# Free-tier Gemini keys allow only a few requests per minute (e.g. GEMINI_RPM=5);
# setting it paces all Gemini calls instead of failing them with 429s.
if rpm = System.get_env("GEMINI_RPM") do
  config :agent_manager, AgentManager.Models,
    providers: [gemini: [rate_limit: {String.to_integer(rpm), :minute}, max_retries: 3]]
end

# Thinking/reasoning for Gemini's OpenAI-compatible endpoint (thinking tokens
# are billed as output), e.g.
#   GEMINI_REASONING_EFFORT=minimal
# Gemini 3 models can't turn thinking off: "none" is rejected with HTTP 400
# there (it's only valid for Gemini 2.5 Flash / Flash-Lite).
if effort = System.get_env("GEMINI_REASONING_EFFORT") do
  config :agent_manager, AgentManager.Models,
    providers: [gemini: [extra_body: %{reasoning_effort: effort}]]
end

# Bearer token for the HTTP API. When set, every API route requires
# `Authorization: Bearer <token>`; the admin routes always require it.
if token = System.get_env("API_TOKEN") do
  config :agent_manager, :api_token, token
end

# Reverse proxies in front of the app (comma-separated IPs, e.g. "127.0.0.1,::1"):
# only their X-Forwarded-For is trusted for the client IP used by rate limits.
if proxies = System.get_env("TRUSTED_PROXIES") do
  config :agent_manager,
         :trusted_proxies,
         proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# WhatsApp Cloud API (see README, "WhatsApp showcase").
whatsapp =
  for {key, var} <- [
        token: "WHATSAPP_TOKEN",
        phone_number_id: "WHATSAPP_PHONE_NUMBER_ID",
        verify_token: "WHATSAPP_VERIFY_TOKEN",
        app_secret: "WHATSAPP_APP_SECRET",
        api_version: "WHATSAPP_API_VERSION",
        base_url: "WHATSAPP_API_BASE"
      ],
      value = System.get_env(var),
      value not in [nil, ""],
      do: {key, value}

if whatsapp != [] do
  config :agent_manager, AgentManager.WhatsApp, whatsapp
end

# LIVE_TRACE=true prints what happens inside on the console, live: WhatsApp
# messages in and out, pipeline steps, model and tool calls, training.
if System.get_env("LIVE_TRACE") in ~w(true 1) do
  config :agent_manager, AgentManager.Handlers.LiveTrace, enabled: true
end

# HTTP channel: also POST every reply to this URL (besides the outbox).
if url = System.get_env("HTTP_CHANNEL_CALLBACK_URL") do
  config :agent_manager, AgentManager.Channels.Http, callback_url: url
end

# SHOWCASE_SEED=true creates (and trains) the ready-made showcase bots at boot.
if System.get_env("SHOWCASE_SEED") in ~w(true 1) do
  config :agent_manager, AgentManager.Showcase, seed_on_boot: true
end

# MCP servers can also be given as JSON, e.g.
#   MCP_SERVERS='[{"name":"crm","transport":"http","url":"https://crm.example.com/mcp"}]'
if mcp_json = System.get_env("MCP_SERVERS") do
  config :agent_manager, AgentManager.MCP, servers: Jason.decode!(mcp_json)
end

if config_env() == :prod do
  # Without a token the bot API (and every model call it can make) is open to
  # anyone, so production refuses to start without one.
  if System.get_env("API_TOKEN") in [nil, ""] do
    raise """
    environment variable API_TOKEN is missing.
    It protects the HTTP API, the admin routes and /socket. Generate one with:
    mix phx.gen.secret 32
    """
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :agent_manager, AgentManager.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :agent_manager, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :agent_manager, AgentManagerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :agent_manager, AgentManagerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :agent_manager, AgentManagerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# PHX_IP=127.0.0.1 listens on loopback only, for a reverse proxy on the same
# host (otherwise prod listens on every interface, where a firewall must keep
# the port closed). Last, so it wins over the prod default above.
if ip = System.get_env("PHX_IP") do
  {:ok, address} = ip |> String.to_charlist() |> :inet.parse_address()
  config :agent_manager, AgentManagerWeb.Endpoint, http: [ip: address]
end
