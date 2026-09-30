import Config

# Local secrets: in dev, KEY=VALUE lines from a gitignored `.env` are exported
# before any other config is read (see `.env.example`). Variables already set
# in the shell win. Tests never read it (a developer's models, tokens and
# WhatsApp secret would leak into them); production reads real environment
# variables only.
if config_env() == :dev and File.exists?(Path.expand("../.env", __DIR__)) do
  for line <- File.stream!(Path.expand("../.env", __DIR__)),
      line = String.trim(line),
      line != "" and not String.starts_with?(line, "#"),
      [key, value] <- [String.split(line, "=", parts: 2)],
      System.get_env(String.trim(key)) in [nil, ""] do
    System.put_env(String.trim(key), value |> String.trim() |> String.trim("\""))
  end
end

config :agent_manager,
  ecto_repos: [AgentManager.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  store: AgentManager.Store.Ecto,
  vector_store: AgentManager.VectorStore.Pgvector,
  publish_step_events: true

config :agent_manager, AgentManager.Repo,
  types: AgentManager.PostgrexTypes,
  migration_primary_key: [type: :binary_id]

# Models are addressed as "provider:model". Providers are pure configuration:
# add an OpenAI-compatible gateway, a second Ollama host or a local Bumblebee
# serving here and any bot can switch to it with one PATCH.
config :agent_manager, AgentManager.Models,
  providers: [
    openai: [adapter: AgentManager.Models.Adapters.OpenAI, api_key: {:system, "OPENAI_API_KEY"}],
    anthropic: [
      adapter: AgentManager.Models.Adapters.Anthropic,
      api_key: {:system, "ANTHROPIC_API_KEY"}
    ],
    # Gemini through Google's OpenAI-compatible endpoint (chat + embeddings).
    gemini: [
      adapter: AgentManager.Models.Adapters.OpenAI,
      base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      api_key: {:system, "GEMINI_API_KEY"}
    ],
    ollama: [adapter: AgentManager.Models.Adapters.Ollama, base_url: {:system, "OLLAMA_URL"}],
    fake: [adapter: AgentManager.Models.Adapters.Fake]
  ],
  # Bare model names from the 1.0 API keep working.
  aliases: %{
    "gpt-3.5-turbo" => "openai:gpt-4o-mini",
    "gpt-4" => "openai:gpt-4o",
    "gpt-4o" => "openai:gpt-4o"
  },
  defaults: [
    chat: "openai:gpt-4o-mini",
    utility: nil,
    embedding: "openai:text-embedding-3-small"
  ],
  # Prompt token budget (instructions + retrieved context + history) per model.
  budgets: %{
    "openai" => 12_000,
    "anthropic" => 16_000,
    "gemini" => 16_000,
    "ollama" => 6_000,
    "openai:gpt-4o-mini" => 12_000
  }

config :agent_manager, AgentManager.Training.Coordinator, max_concurrency: 2

config :agent_manager, AgentManagerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AgentManagerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AgentManager.PubSub,
  live_view: [signing_salt: "VBQdPvNJ"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
