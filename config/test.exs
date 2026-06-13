import Config

# Tests run without a database or network: in-memory storage and the
# deterministic Fake model provider.
config :agent_manager,
  store: AgentManager.Store.Memory,
  vector_store: AgentManager.Store.Memory.Vectors

config :agent_manager, AgentManager.Models,
  providers: [
    fake: [adapter: AgentManager.Models.Adapters.Fake],
    alt: [adapter: AgentManager.Models.Adapters.Fake]
  ],
  aliases: %{},
  defaults: [chat: "fake:chat", utility: nil, embedding: "fake:embed"],
  budgets: %{"fake" => 4_000}

config :agent_manager, AgentManager.Handlers.Webhooks, endpoints: []

config :agent_manager, AgentManagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CRIudYVcdSoO9mP4mZA1jb4CGQXnkVQpxrxs5mLsRjOeB2IMFG/Sh/bXfrZzy3PA",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Job-timing "minutes" last 20ms in tests.
config :agent_manager, AgentManager.Conversations.Server, minute_ms: 20
