defmodule AgentManager.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentManagerWeb.Telemetry,
      AgentManager.Repo,
      {DNSCluster, query: Application.get_env(:agent_manager, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AgentManager.PubSub},
      {Task.Supervisor, name: AgentManager.TaskSupervisor},
      AgentManagerWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AgentManager.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentManagerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
