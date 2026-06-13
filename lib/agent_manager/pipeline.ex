defmodule AgentManager.Pipeline do
  @moduledoc """
  Composable processing pipelines.

  ## Declaring a pipeline

      defmodule MyPipeline do
        use AgentManager.Pipeline

        step Normalize
        step Classify, retry: 2, timeout: 5_000
        parallel [DetectLanguage, {Retrieve, k: 20}]
        step Enrich, when: :needs_enrichment, on_error: :continue
        step :log, fn ctx, _opts -> IO.inspect(ctx.assigns); {:ok, ctx} end
        step Respond
      end

      MyPipeline.run(%{text: "hello"}, bot: bot)

  ## Changing a pipeline without touching its module

  Steps are plain data (`AgentManager.Pipeline.Spec`), so a pipeline can be
  reshaped at runtime:

      MyPipeline.steps()
      |> Pipeline.replace(Classify, {LLMClassify, model: "anthropic:claude-haiku-4-5"})
      |> Pipeline.insert_after(Normalize, Redact)
      |> then(&Pipeline.run(MyPipeline, input, steps: &1))

  or from config, which `use AgentManager.Pipeline` modules read on every run:

      config :agent_manager, MyPipeline,
        steps: [Normalize, Respond]                    # full replacement
        # or
        edits: [{:remove, Enrich}, {:insert_before, Respond, Audit}]
  """

  alias AgentManager.Pipeline.{Context, Runner, Spec}

  defmacro __using__(_opts) do
    quote do
      import AgentManager.Pipeline, only: [step: 1, step: 2, step: 3, parallel: 1, parallel: 2]
      Module.register_attribute(__MODULE__, :pipeline_steps, accumulate: true)
      @before_compile AgentManager.Pipeline
    end
  end

  # Step declarations may contain anonymous functions (`when:`, recover
  # callbacks, function steps), which can't live in module attributes. So each
  # declaration is stored as AST (with aliases resolved at the call site) and
  # spliced into `default_steps/0`, where it is evaluated at runtime.

  @doc "Declares a step: a module, `{module, opts}`, or `name, fn ctx, opts -> ... end`."
  defmacro step(impl, opts \\ [])

  defmacro step(name, {:fn, _, _} = fun) do
    store(quote(do: {unquote(fun), [name: unquote(name)]}), __CALLER__)
  end

  defmacro step(impl, opts) do
    store(quote(do: {unquote(impl), unquote(opts)}), __CALLER__)
  end

  defmacro step(name, {:fn, _, _} = fun, opts) do
    store(quote(do: {unquote(fun), Keyword.put(unquote(opts), :name, unquote(name))}), __CALLER__)
  end

  @doc "Runs `branches` concurrently; see `AgentManager.Pipeline.Spec`."
  defmacro parallel(branches, opts \\ []) do
    store(quote(do: {:parallel, unquote(branches), unquote(opts)}), __CALLER__)
  end

  defp store(ast, env) do
    ast =
      Macro.prewalk(ast, fn
        {:__aliases__, _, _} = alias_ast -> Macro.expand(alias_ast, env)
        other -> other
      end)

    quote do: @pipeline_steps(unquote(Macro.escape(ast)))
  end

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:pipeline_steps) |> Enum.reverse()

    quote do
      @doc "The pipeline's steps as declared in the module."
      def default_steps, do: Enum.map([unquote_splicing(entries)], &Spec.normalize/1)

      @doc "The effective steps: defaults, adjusted by application config."
      def steps, do: AgentManager.Pipeline.configured_steps(__MODULE__, default_steps())

      @doc "Runs the pipeline. `input` may be a map or an existing `Context`."
      def run(input, opts \\ []), do: AgentManager.Pipeline.run(__MODULE__, input, opts)
    end
  end

  @doc """
  Runs a pipeline module, or an ad-hoc list of steps, against `input`.

  Options: `:bot`, `:assigns`, `:id` (correlation id), `:until` (step name to
  stop after), `:steps` (override the step list for this run only), `:name`.
  """
  @spec run(module() | [term()], map() | Context.t(), keyword()) ::
          {:ok, Context.t()} | {:error, term(), Context.t()}
  def run(pipeline, input, opts \\ [])

  def run(pipeline, %Context{} = ctx, opts) do
    {name, steps} = resolve(pipeline, opts)
    ctx = %{ctx | pipeline: name}
    meta = %{pipeline: name, context_id: ctx.id}

    :telemetry.span([:agent_manager, :pipeline, :run], meta, fn ->
      result = Runner.run(steps, ctx, opts)
      {result, Map.put(meta, :status, elem(result, 0))}
    end)
  end

  def run(pipeline, input, opts), do: run(pipeline, Context.new(input, opts), opts)

  defp resolve(pipeline, opts) when is_atom(pipeline),
    do: {pipeline, normalize(opts[:steps] || pipeline.steps())}

  defp resolve(steps, opts) when is_list(steps), do: {opts[:name] || :anonymous, normalize(steps)}

  @doc false
  def configured_steps(module, defaults) do
    config = Application.get_env(:agent_manager, module, [])

    case config[:steps] do
      nil -> Enum.reduce(config[:edits] || [], defaults, &apply_edit/2)
      steps -> normalize(steps)
    end
  end

  defp apply_edit({:remove, name}, steps), do: remove(steps, name)
  defp apply_edit({:replace, name, new}, steps), do: replace(steps, name, new)
  defp apply_edit({:insert_before, name, new}, steps), do: insert_before(steps, name, new)
  defp apply_edit({:insert_after, name, new}, steps), do: insert_after(steps, name, new)
  defp apply_edit({:append, new}, steps), do: steps ++ [Spec.normalize(new)]

  def normalize(steps), do: Enum.map(steps, &Spec.normalize/1)

  @doc "Names of the steps in order; parallel groups become nested lists."
  def names(steps) do
    Enum.map(normalize(steps), fn
      %Spec{kind: :parallel, impl: branches} -> names(branches)
      %Spec{name: name} -> name
    end)
  end

  def remove(steps, name), do: steps |> normalize() |> Enum.reject(&(&1.name == name))

  def replace(steps, name, new), do: splice(steps, name, fn _old -> [Spec.normalize(new)] end)

  def insert_before(steps, name, new), do: splice(steps, name, &[Spec.normalize(new), &1])

  def insert_after(steps, name, new), do: splice(steps, name, &[&1, Spec.normalize(new)])

  defp splice(steps, name, fun) do
    steps = normalize(steps)

    unless Enum.any?(steps, &(&1.name == name)) do
      raise ArgumentError, "no step named #{inspect(name)} in pipeline"
    end

    Enum.flat_map(steps, fn
      %Spec{name: ^name} = spec -> fun.(spec)
      spec -> [spec]
    end)
  end
end
