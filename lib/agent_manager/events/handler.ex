defmodule AgentManager.Events.Handler do
  @moduledoc """
  Behaviour + `use` macro for long-lived event consumers.

      defmodule MyApp.AuditLog do
        use AgentManager.Events.Handler, subscribe: ["message.answered"]

        @impl true
        def handle_event(event, state) do
          IO.inspect(event)
          {:ok, state}
        end
      end

  A handler is a `GenServer` that subscribes on start, so when it crashes the
  supervisor restarts it and it re-subscribes. Exceptions inside
  `handle_event/2` are caught and logged per event, so one bad event cannot
  put a handler into a restart loop and take `Events.Supervisor` down.
  """

  alias AgentManager.Events.Event

  @callback init_state(opts :: keyword()) :: term()
  @callback handle_event(Event.t(), state :: term()) :: {:ok, term()}
  @optional_callbacks init_state: 1

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour AgentManager.Events.Handler
      use GenServer
      require Logger

      @subscriptions Keyword.get(opts, :subscribe, [:all])

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      def subscriptions, do: @subscriptions

      @impl GenServer
      def init(opts) do
        Enum.each(@subscriptions, &AgentManager.Events.subscribe/1)

        state =
          if function_exported?(__MODULE__, :init_state, 1),
            do: apply(__MODULE__, :init_state, [opts]),
            else: opts

        {:ok, state}
      end

      @impl GenServer
      def handle_info({:event, event}, state) do
        try do
          {:ok, state} = handle_event(event, state)
          {:noreply, state}
        rescue
          error ->
            Logger.error(
              "[#{inspect(__MODULE__)}] failed on #{event.type}: " <>
                Exception.format(:error, error, __STACKTRACE__)
            )

            {:noreply, state}
        end
      end

      def handle_info(_other, state), do: {:noreply, state}
    end
  end
end
