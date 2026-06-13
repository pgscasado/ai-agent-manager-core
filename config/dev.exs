import Config

# STORE=memory runs everything in ETS - no Postgres needed.
if System.get_env("STORE") == "memory" do
  config :agent_manager,
    store: AgentManager.Store.Memory,
    vector_store: AgentManager.Store.Memory.Vectors
end

# MODELS=fake answers without any provider (handy for exploring the API).
if System.get_env("MODELS") == "fake" do
  config :agent_manager, AgentManager.Models,
    defaults: [chat: "fake:chat", utility: nil, embedding: "fake:embed"]
end

config :agent_manager, AgentManager.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "agent_manager_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :agent_manager, AgentManagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "+SIg/Rp5LLlSK9IQGSYO11A8fV2L+2msMh3My3A9yVW5+0si2ht23oPij3cDJ38B",
  watchers: []

config :agent_manager, dev_routes: true
config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
