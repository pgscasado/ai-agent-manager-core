defmodule AgentManager.Application do
  @moduledoc """
  Supervision tree:

      AgentManager.Supervisor (one_for_one)
      ├── AgentManagerWeb.Telemetry
      ├── AgentManager.Repo                    (when a Postgres-backed store is configured)
      ├── AgentManager.Store.Memory            (when the in-memory store is configured)
      ├── DNSCluster
      ├── Phoenix.PubSub (AgentManager.PubSub) - the event bus
      ├── Task.Supervisor (AgentManager.TaskSupervisor) - step timeouts, parallel steps, webhooks
      ├── AgentManager.Models.Supervisor       - local model servings (Bumblebee), if configured
      ├── AgentManager.Events.Supervisor       - one process per event handler
      ├── AgentManager.Conversations.Root (rest_for_one)
      │   ├── Registry {bot_id, user_id} -> pid
      │   └── DynamicSupervisor - one Conversations.Server per active conversation
      ├── AgentManager.Training.Root (rest_for_one)
      │   ├── Registry bot_id -> running job (lets a restarted coordinator adopt jobs)
      │   ├── Task.Supervisor - training jobs
      │   └── Training.Coordinator - queue + concurrency limit
      ├── AgentManager.QA.Root (rest_for_one)
      │   ├── Registry bot_id -> running audit session (one per bot)
      │   └── Task.Supervisor - audit sessions
      ├── AgentManager.MCP.Root (rest_for_one)
      │   ├── Registry server name -> client (value: status + tool list)
      │   ├── DynamicSupervisor - one MCP.Client per server
      │   └── Task - starts the configured servers at boot
      ├── AgentManager.Showcase.Root (rest_for_one)  - the WhatsApp showcase
      │   ├── Registry phone -> session
      │   ├── DynamicSupervisor - one Showcase.Session per active WhatsApp user
      │   └── Task - seeds the ready-made bots at boot (SHOWCASE_SEED=true)
      └── AgentManagerWeb.Endpoint

  Handlers start before anything that publishes, so no event is missed at boot.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [AgentManagerWeb.Telemetry] ++
        storage_children() ++
        [
          {DNSCluster, query: Application.get_env(:agent_manager, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: AgentManager.PubSub},
          {Task.Supervisor, name: AgentManager.TaskSupervisor},
          AgentManager.RateLimit,
          AgentManager.Channels.Http,
          AgentManager.Models.Supervisor,
          AgentManager.Events.Supervisor,
          supervisor(AgentManager.Conversations.Root, [
            {Registry, keys: :unique, name: AgentManager.Conversations.Registry},
            {DynamicSupervisor,
             name: AgentManager.Conversations.Supervisor, strategy: :one_for_one}
          ]),
          supervisor(AgentManager.Training.Root, [
            {Registry, keys: :unique, name: AgentManager.Training.Registry},
            {Task.Supervisor, name: AgentManager.Training.TaskSupervisor},
            AgentManager.Training.Coordinator
          ]),
          supervisor(AgentManager.QA.Root, [
            {Registry, keys: :unique, name: AgentManager.QA.Registry},
            {Task.Supervisor, name: AgentManager.QA.TaskSupervisor}
          ]),
          supervisor(AgentManager.MCP.Root, [
            {Registry, keys: :unique, name: AgentManager.MCP.Registry},
            {DynamicSupervisor, name: AgentManager.MCP.Supervisor, strategy: :one_for_one},
            {Task, &AgentManager.MCP.start_configured/0}
          ]),
          supervisor(AgentManager.Showcase.Root, [
            {Registry, keys: :unique, name: AgentManager.Showcase.Registry},
            {DynamicSupervisor, name: AgentManager.Showcase.Supervisor, strategy: :one_for_one},
            {Task, &AgentManager.Showcase.Seeds.run_on_boot/0}
          ]),
          AgentManagerWeb.Endpoint
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AgentManager.Supervisor)
  end

  defp storage_children do
    backends = [AgentManager.Store.impl(), AgentManager.VectorStore.impl()]

    Enum.uniq(
      if(
        Enum.any?(
          backends,
          &(&1 in [AgentManager.Store.Ecto, AgentManager.VectorStore.Pgvector])
        ),
        do: [AgentManager.Repo],
        else: []
      ) ++
        if(
          Enum.any?(
            backends,
            &(&1 in [AgentManager.Store.Memory, AgentManager.Store.Memory.Vectors])
          ),
          do: [AgentManager.Store.Memory],
          else: []
        )
    )
  end

  defp supervisor(name, children) do
    %{
      id: name,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one, name: name]]}
    }
  end

  @impl true
  def config_change(changed, _new, removed) do
    AgentManagerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule AgentManager.Events.Supervisor do
  @moduledoc """
  Starts every configured event handler under one supervisor.

      config :agent_manager, AgentManager.Events.Supervisor,
        handlers: [MessageRecorder, UsageRecorder, TrainingRecorder, EventLogger, Webhooks, MyHandler]
  """
  use Supervisor

  @default [
    AgentManager.Handlers.MessageRecorder,
    AgentManager.Handlers.UsageRecorder,
    AgentManager.Handlers.TrainingRecorder,
    AgentManager.Handlers.EventLogger,
    AgentManager.Handlers.Webhooks,
    AgentManager.QA.Auditor
  ]

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def handlers do
    handlers = Application.get_env(:agent_manager, __MODULE__, [])[:handlers] || @default
    trace = AgentManager.Handlers.LiveTrace

    # LIVE_TRACE=true prints events on the console
    if trace.enabled?() and trace not in handlers, do: handlers ++ [trace], else: handlers
  end

  @impl true
  def init(_opts),
    do: Supervisor.init(handlers(), strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
end

defmodule AgentManager.Models.Supervisor do
  @moduledoc """
  Hosts long-lived model processes: a registry for named servings plus one
  child per entry in `config :agent_manager, AgentManager.Models, servings: [...]`
  (e.g. Bumblebee `Nx.Serving`s that batch requests from the whole node).
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    servings = Application.get_env(:agent_manager, AgentManager.Models, [])[:servings] || []

    serving_children =
      for {spec, kind} <- servings do
        {:ok, resolved} = AgentManager.Models.resolve(spec, kind)
        {resolved.adapter, {resolved.name, kind}}
      end

    Supervisor.init(
      [
        {Registry, keys: :unique, name: AgentManager.Models.Registry},
        {DynamicSupervisor, name: AgentManager.Models.LimiterSupervisor, strategy: :one_for_one}
        | serving_children
      ],
      strategy: :one_for_one
    )
  end
end
