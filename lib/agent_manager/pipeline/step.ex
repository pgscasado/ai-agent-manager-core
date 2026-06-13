defmodule AgentManager.Pipeline.Step do
  @moduledoc """
  A single unit of work in a pipeline.

      defmodule MyStep do
        use AgentManager.Pipeline.Step

        @impl true
        def call(ctx, opts) do
          {:ok, Context.assign(ctx, :greeting, "hi " <> opts[:name])}
        end
      end

  Return values:

    * `{:ok, ctx}` - continue (the step may still `Context.halt/2` the ctx)
    * `{:halt, ctx}` - stop successfully; `ctx.result` is the output
    * `{:error, reason, ctx}` - failure, handled by the step's `on_error` policy

  Returning a bare `%Context{}` is treated as `{:ok, ctx}`.
  """

  alias AgentManager.Pipeline.Context

  @type result ::
          {:ok, Context.t()} | {:halt, Context.t()} | {:error, term(), Context.t()} | Context.t()

  @callback init(opts :: keyword()) :: term()
  @callback call(Context.t(), opts :: term()) :: result()
  @optional_callbacks init: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour AgentManager.Pipeline.Step
      alias AgentManager.Pipeline.Context
      require Logger
    end
  end
end
