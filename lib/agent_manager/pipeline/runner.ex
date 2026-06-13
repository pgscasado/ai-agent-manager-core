defmodule AgentManager.Pipeline.Runner do
  @moduledoc false
  # Executes a list of `Spec`s against a `Context`.
  #
  # Emits `[:agent_manager, :pipeline, :step, :start | :stop]` telemetry for
  # every step and, when enabled, a `pipeline.step.completed` event so external
  # observers can follow a run live.

  require Logger

  alias AgentManager.Pipeline.{Context, Spec}

  @task_sup AgentManager.TaskSupervisor

  @spec run([Spec.t()], Context.t(), keyword()) ::
          {:ok, Context.t()} | {:error, term(), Context.t()}
  def run(specs, %Context{} = ctx, opts \\ []) do
    until = opts[:until]

    Enum.reduce_while(specs, {:ok, ctx}, fn spec, {:ok, ctx} ->
      case execute(spec, ctx) do
        {:ok, %Context{halted: true} = ctx} -> {:halt, {:ok, ctx}}
        {:ok, ctx} when until != nil and spec.name == until -> {:halt, {:ok, ctx}}
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, reason, ctx} -> {:halt, {:error, reason, ctx}}
      end
    end)
  end

  defp execute(%Spec{} = spec, ctx) do
    if should_run?(spec, ctx) do
      started = System.monotonic_time()
      meta = %{pipeline: ctx.pipeline, step: spec.name, context_id: ctx.id}

      :telemetry.execute(
        [:agent_manager, :pipeline, :step, :start],
        %{system_time: System.system_time()},
        meta
      )

      {status, outcome} =
        case attempt(spec, ctx, spec.retry) do
          {:ok, ctx} -> {:ok, {:ok, ctx}}
          {:error, reason, ctx} -> {:error, handle_error(spec, ctx, reason)}
        end

      duration = System.monotonic_time() - started
      duration_us = System.convert_time_unit(duration, :native, :microsecond)

      :telemetry.execute(
        [:agent_manager, :pipeline, :step, :stop],
        %{duration: duration},
        Map.put(meta, :status, status)
      )

      outcome = map_ctx(outcome, &%{&1 | trace: &1.trace ++ [{spec.name, status, duration_us}]})
      publish_step(outcome, spec, status, duration_us)
      outcome
    else
      {:ok, %{ctx | trace: ctx.trace ++ [{spec.name, :skipped, 0}]}}
    end
  end

  defp should_run?(%Spec{when: nil}, _ctx), do: true
  defp should_run?(%Spec{when: key}, ctx) when is_atom(key), do: !!Context.get(ctx, key)
  defp should_run?(%Spec{when: fun}, ctx) when is_function(fun, 1), do: !!fun.(ctx)

  defp attempt(spec, ctx, retries_left) do
    case invoke(spec, ctx) do
      {:ok, ctx} ->
        {:ok, ctx}

      {:error, reason, _ctx} when retries_left > 0 ->
        Logger.warning("[pipeline] #{inspect(spec.name)} failed (#{inspect(reason)}), retrying")
        Process.sleep(backoff(spec.retry - retries_left))
        attempt(spec, ctx, retries_left - 1)

      error ->
        error
    end
  end

  defp backoff(n), do: min(100 * Integer.pow(2, n), 2_000)

  defp invoke(%Spec{timeout: nil} = spec, ctx), do: safe_call(spec, ctx)

  defp invoke(%Spec{timeout: timeout} = spec, ctx) do
    task = Task.Supervisor.async_nolink(@task_sup, fn -> safe_call(spec, ctx) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}, ctx}
      nil -> {:error, :timeout, ctx}
    end
  end

  defp safe_call(spec, ctx) do
    spec |> call(ctx) |> normalize_result(ctx)
  rescue
    exception ->
      Logger.error(
        "[pipeline] #{inspect(spec.name)} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, exception, ctx}
  catch
    kind, reason -> {:error, {kind, reason}, ctx}
  end

  defp call(%Spec{kind: :module, impl: mod, opts: opts}, ctx), do: mod.call(ctx, opts)
  defp call(%Spec{kind: :function, impl: fun, opts: opts}, ctx), do: fun.(ctx, opts)
  defp call(%Spec{kind: :parallel, impl: branches}, ctx), do: run_parallel(branches, ctx)

  defp normalize_result({:ok, %Context{} = ctx}, _), do: {:ok, ctx}
  defp normalize_result({:halt, %Context{} = ctx}, _), do: {:ok, %{ctx | halted: true}}
  defp normalize_result({:error, reason, %Context{} = ctx}, _), do: {:error, reason, ctx}
  defp normalize_result({:error, reason}, ctx), do: {:error, reason, ctx}
  defp normalize_result(%Context{} = ctx, _), do: {:ok, ctx}
  defp normalize_result(other, ctx), do: {:error, {:bad_step_return, other}, ctx}

  defp handle_error(%Spec{on_error: :halt}, ctx, reason),
    do: {:error, reason, Context.add_error(ctx, reason)}

  defp handle_error(%Spec{on_error: :continue}, ctx, reason),
    do: {:ok, Context.add_error(ctx, reason)}

  defp handle_error(%Spec{on_error: {:recover, fun}}, ctx, reason),
    do: {:ok, fun.(Context.add_error(ctx, reason), reason)}

  # Each branch gets the same ctx and runs concurrently in its own process.
  # Their assigns/usage/errors/trace are merged back in declaration order;
  # the first branch that halts decides the result.
  defp run_parallel(branches, ctx) do
    results =
      @task_sup
      |> Task.Supervisor.async_stream_nolink(branches, &execute(&1, ctx),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:exit, reason}, ctx}
      end)

    merged = merge(ctx, results)

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      {:error, reason, _} -> {:error, reason, merged}
      nil -> {:ok, merged}
    end
  end

  defp merge(base, results) do
    Enum.reduce(results, base, fn result, acc ->
      branch = last(result)
      changed = Map.filter(branch.assigns, fn {k, v} -> Map.get(base.assigns, k) !== v end)
      usage_delta = Map.new(branch.usage, fn {k, v} -> {k, v - Map.get(base.usage, k, 0)} end)

      acc =
        %{
          acc
          | assigns: Map.merge(acc.assigns, changed),
            errors: acc.errors ++ Enum.drop(branch.errors, length(base.errors)),
            trace: acc.trace ++ Enum.drop(branch.trace, length(base.trace))
        }
        |> Context.add_usage(usage_delta)

      if branch.halted and not acc.halted,
        do: %{acc | halted: true, result: branch.result},
        else: acc
    end)
  end

  defp last(tuple), do: elem(tuple, tuple_size(tuple) - 1)

  defp map_ctx({:ok, ctx}, fun), do: {:ok, fun.(ctx)}
  defp map_ctx({:error, reason, ctx}, fun), do: {:error, reason, fun.(ctx)}

  defp publish_step(outcome, spec, status, duration_us) do
    if Application.get_env(:agent_manager, :publish_step_events, true) and spec.kind != :parallel do
      ctx = last(outcome)

      Context.publish(ctx, "pipeline.step.completed", %{
        pipeline: ctx.pipeline,
        step: spec.name,
        status: status,
        halted: ctx.halted,
        duration_us: duration_us
      })
    end
  end
end
