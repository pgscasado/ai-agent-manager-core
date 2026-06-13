defmodule AgentManager.Repo do
  use Ecto.Repo,
    otp_app: :agent_manager,
    adapter: Ecto.Adapters.Postgres
end

Postgrex.Types.define(
  AgentManager.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
