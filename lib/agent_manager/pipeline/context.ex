defmodule AgentManager.Pipeline.Context do
  @moduledoc """
  The value threaded through every pipeline step (think `Plug.Conn`).

    * `input`   - what the pipeline was started with (immutable by convention)
    * `assigns` - scratch space steps use to hand data to later steps
    * `result`  - the pipeline's output; set it and `halt/2` to short-circuit
    * `usage`   - token usage accumulated across every model call
    * `trace`   - `{step, status, duration_us}` per executed step, in order
  """

  alias AgentManager.Events

  defstruct id: nil,
            pipeline: nil,
            bot: nil,
            input: %{},
            assigns: %{},
            result: nil,
            halted: false,
            errors: [],
            usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
            trace: []

  @type t :: %__MODULE__{
          id: String.t(),
          pipeline: module() | atom() | nil,
          bot: struct() | nil,
          input: map(),
          assigns: map(),
          result: term(),
          halted: boolean(),
          errors: [term()],
          usage: map(),
          trace: [{term(), atom(), non_neg_integer()}]
        }

  @spec new(map() | keyword(), keyword()) :: t()
  def new(input, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || Ecto.UUID.generate(),
      bot: opts[:bot],
      input: Map.new(input),
      assigns: Map.new(opts[:assigns] || %{})
    }
  end

  def assign(%__MODULE__{} = ctx, key, value),
    do: %{ctx | assigns: Map.put(ctx.assigns, key, value)}

  def assign(%__MODULE__{} = ctx, kv), do: %{ctx | assigns: Enum.into(kv, ctx.assigns)}

  def get(%__MODULE__{assigns: assigns}, key, default \\ nil), do: Map.get(assigns, key, default)

  @doc "Stops the pipeline after the current step, with `result` as its output."
  def halt(%__MODULE__{} = ctx, result), do: %{ctx | result: result, halted: true}
  def halt(%__MODULE__{} = ctx), do: %{ctx | halted: true}

  def put_result(%__MODULE__{} = ctx, result), do: %{ctx | result: result}

  def add_error(%__MODULE__{} = ctx, error), do: %{ctx | errors: ctx.errors ++ [error]}

  def add_usage(%__MODULE__{} = ctx, nil), do: ctx

  def add_usage(%__MODULE__{usage: usage} = ctx, new) do
    %{ctx | usage: Map.new(usage, fn {k, v} -> {k, v + (Map.get(new, k) || 0)} end)}
  end

  def bot_id(%__MODULE__{bot: %{id: id}}), do: id
  def bot_id(_), do: nil

  @doc "Options that tie a model call to this run (bot's keys + event correlation)."
  def model_opts(%__MODULE__{} = ctx) do
    keys =
      case ctx.bot do
        %{model_config: %{api_keys: keys}} when is_map(keys) -> keys
        _ -> %{}
      end

    # `budget: :qa` for answers given to QA (see AgentManager.Budget)
    [api_keys: keys, bot_id: bot_id(ctx), correlation_id: ctx.id, budget: ctx.assigns[:budget]]
  end

  @doc "Publishes an event correlated with this pipeline run."
  def publish(%__MODULE__{} = ctx, type, payload \\ %{}) do
    Events.publish(type, payload, bot_id: bot_id(ctx), correlation_id: ctx.id)
  end
end
