defmodule AgentManager.PipelineTest do
  use AgentManager.Case

  alias AgentManager.{Events, Pipeline}
  alias AgentManager.Pipeline.Context

  defmodule Add do
    use AgentManager.Pipeline.Step
    @impl true
    def call(ctx, opts),
      do: {:ok, Context.assign(ctx, :n, Context.get(ctx, :n, 0) + (opts[:by] || 1))}
  end

  defmodule Stop do
    use AgentManager.Pipeline.Step
    @impl true
    def call(ctx, _opts), do: {:halt, Context.halt(ctx, :stopped)}
  end

  defmodule Boom do
    use AgentManager.Pipeline.Step
    @impl true
    def call(_ctx, _opts), do: raise("boom")
  end

  defmodule Flaky do
    use AgentManager.Pipeline.Step
    @impl true
    def call(ctx, opts) do
      if Agent.get_and_update(opts[:agent], &{&1, &1 + 1}) < 2,
        do: {:error, :flaky, ctx},
        else: {:ok, Context.assign(ctx, :flaky, :ok)}
    end
  end

  defmodule Slow do
    use AgentManager.Pipeline.Step
    @impl true
    def call(ctx, opts) do
      Process.sleep(opts[:ms])
      {:ok, Context.assign(ctx, opts[:key], self())}
    end
  end

  defmodule Declared do
    use AgentManager.Pipeline

    step(Add)
    step(Add, by: 10, name: :add_ten)
    step(:double, fn ctx, _ -> {:ok, Context.assign(ctx, :n, ctx.assigns.n * 2)} end)
    step(Stop, when: fn ctx -> ctx.assigns.n > 100 end)
    step(:finish, fn ctx, _ -> {:ok, Context.put_result(ctx, ctx.assigns.n)} end)
  end

  test "a declared pipeline runs its steps in order and records a trace" do
    assert {:ok, ctx} = Declared.run(%{})
    assert ctx.result == 22
    assert Enum.map(ctx.trace, &elem(&1, 0)) == [Add, :add_ten, :double, Stop, :finish]
    assert {Stop, :skipped, 0} in ctx.trace
  end

  test "halt short-circuits and becomes the result" do
    assert {:ok, ctx} = Pipeline.run([{Add, by: 200}, Stop, Boom], %{})
    assert ctx.halted and ctx.result == :stopped
  end

  test "exceptions become errors; on_error decides what happens next" do
    assert {:error, %RuntimeError{message: "boom"}, _} = Pipeline.run([Boom, Add], %{})
    assert {:ok, ctx} = Pipeline.run([{Boom, on_error: :continue}, Add], %{})
    assert ctx.assigns.n == 1
    assert [%RuntimeError{}] = ctx.errors

    recover = fn ctx, _reason -> Context.halt(ctx, :recovered) end

    assert {:ok, %{result: :recovered}} =
             Pipeline.run([{Boom, on_error: {:recover, recover}}, Add], %{})
  end

  test "retries failed steps" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    assert {:error, :flaky, _} = Pipeline.run([{Flaky, agent: agent, retry: 1}], %{})
    Agent.update(agent, fn _ -> 0 end)
    assert {:ok, %{assigns: %{flaky: :ok}}} = Pipeline.run([{Flaky, agent: agent, retry: 2}], %{})
  end

  test "timeouts kill the step's supervised task" do
    assert {:error, :timeout, _} = Pipeline.run([{Slow, ms: 500, key: :x, timeout: 50}], %{})
  end

  test "parallel branches run concurrently in separate processes and merge" do
    steps = [{:parallel, [{Slow, ms: 200, key: :a}, {Slow, ms: 200, key: :b}, {Add, by: 5}], []}]
    {micros, {:ok, ctx}} = :timer.tc(fn -> Pipeline.run(steps, %{}) end)

    assert micros < 390_000
    assert is_pid(ctx.assigns.a) and is_pid(ctx.assigns.b) and ctx.assigns.a != ctx.assigns.b
    assert ctx.assigns.n == 5
  end

  test "parallel branches merge token usage" do
    use_tokens = fn n ->
      fn ctx, _ ->
        {:ok, Context.add_usage(ctx, %{prompt_tokens: n, completion_tokens: 0, total_tokens: n})}
      end
    end

    steps = [{:parallel, [{use_tokens.(3), name: :a}, {use_tokens.(4), name: :b}], []}]
    assert {:ok, ctx} = Pipeline.run(steps, %{})
    assert ctx.usage.total_tokens == 7
  end

  test "pipelines can be reshaped at runtime" do
    steps =
      Declared.steps()
      |> Pipeline.replace(:add_ten, {Add, by: 100, name: :add_hundred})
      |> Pipeline.insert_before(:double, {Add, by: 1, name: :one_more})
      |> Pipeline.remove(Stop)

    assert Pipeline.names(steps) == [Add, :add_hundred, :one_more, :double, :finish]
    assert {:ok, %{result: 204}} = Declared.run(%{}, steps: steps)
  end

  test "config edits apply to every run" do
    Application.put_env(:agent_manager, Declared,
      edits: [{:remove, :double}, {:append, {Add, by: 1000, name: :late}}]
    )

    on_exit(fn -> Application.delete_env(:agent_manager, Declared) end)

    assert Pipeline.names(Declared.steps()) == [Add, :add_ten, Stop, :finish, :late]
    assert {:ok, %{result: 11}} = Declared.run(%{})
  end

  test "until: stops after the named step" do
    assert {:ok, ctx} = Declared.run(%{}, until: :add_ten)
    assert ctx.assigns.n == 11 and is_nil(ctx.result)
  end

  test "each step publishes a correlated event" do
    Events.subscribe("pipeline.step.completed")
    {:ok, ctx} = Pipeline.run([Add], %{}, id: "run-1")
    event = assert_event("pipeline.step.completed")
    assert event.correlation_id == "run-1" and event.payload.step == Add and ctx.id == "run-1"
  end
end
