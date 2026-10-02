defmodule AgentManager.Case do
  @moduledoc """
  Base case: clean in-memory store, default Fake model behaviour, and helpers
  for waiting on events. Tests share global state (ETS, the Fake responder,
  PubSub), so they run synchronously.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import AgentManager.Case
      alias AgentManager.Models.Adapters.Fake
    end
  end

  setup do
    AgentManager.Store.Memory.reset()
    AgentManager.Models.Adapters.Fake.reset()
    AgentManager.RateLimit.reset()

    # Stop conversation processes left from previous tests.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AgentManager.Conversations.Supervisor) do
      DynamicSupervisor.terminate_child(AgentManager.Conversations.Supervisor, pid)
    end

    :ok
  end

  @doc "Waits for an event of `type` (subscribe first!) and returns it."
  defmacro assert_event(type, timeout \\ 2_000) do
    quote do
      assert_receive {:event, %AgentManager.Events.Event{type: unquote(type)} = event},
                     unquote(timeout)

      event
    end
  end

  def create_bot!(attrs \\ %{}) do
    {:ok, bot} = AgentManager.Bots.create(Map.merge(%{"name" => "Test"}, attrs))
    bot
  end

  @doc "Trains `bot` synchronously on `content` and returns the refreshed bot."
  def train!(bot, content) do
    AgentManager.Events.subscribe({:bot, bot.id})
    {:ok, _} = AgentManager.Training.request(bot, content)
    assert_receive {:event, %{type: "training.completed"}}, 5_000
    # the recorder writes FINISHED right after the event; wait for it
    wait_until(fn -> AgentManager.Bots.get(bot.id).training_info.status == :FINISHED end)
    AgentManager.Events.unsubscribe({:bot, bot.id})
    flush_events()
    AgentManager.Bots.get(bot.id)
  end

  def wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.find(fn ok ->
      ok ||
        (System.monotonic_time(:millisecond) > deadline and
           raise("condition not met in #{timeout}ms")) || (Process.sleep(10) && false)
    end)
  end

  def flush_events do
    receive do
      {:event, _} -> flush_events()
    after
      0 -> :ok
    end
  end
end

defmodule AgentManagerWeb.ConnCase do
  @moduledoc "HTTP tests on top of `AgentManager.Case`."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AgentManagerWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import AgentManager.Case
      alias AgentManager.Models.Adapters.Fake
    end
  end

  setup tags do
    AgentManager.Case.__ex_unit__(:setup, tags)

    {:ok,
     conn: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("accept", "application/json")}
  end
end
