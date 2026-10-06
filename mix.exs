defmodule AgentManager.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_manager,
      version: "0.1.0",
      description:
        "AI agent engine: event-driven pipelines, swappable models, tools and MCP on the BEAM",
      source_url: "https://github.com/pgscasado/ai-agent-manager-core",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {AgentManager.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:pgvector, "~> 0.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:nimble_csv, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ] ++ local_model_deps()
  end

  # Local (on-BEAM) models via Bumblebee/Nx are opt-in: they pull in large native
  # toolchains. Enable with LOCAL_MODELS=1 and pick an Nx backend (EXLA, EMLX, ...).
  defp local_model_deps do
    if System.get_env("LOCAL_MODELS") in ~w(1 true) do
      [{:bumblebee, "~> 0.6"}, {:exla, ">= 0.0.0"}]
    else
      []
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
