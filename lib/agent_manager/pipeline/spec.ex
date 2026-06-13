defmodule AgentManager.Pipeline.Spec do
  @moduledoc """
  Normalised description of one pipeline entry.

  Options accepted by `step/2` (and by lists passed to `Pipeline.run/3`):

    * `:name` - identifier used in traces/`until:`; defaults to the module
    * `:when` - `fn ctx -> boolean end`, or an assigns key that must be truthy
    * `:on_error` - `:halt` (default), `:continue`, or `{:recover, fn ctx, reason -> ctx end}`
    * `:retry` - extra attempts on `{:error, _, _}` or crash (default 0)
    * `:timeout` - ms; the step runs in a supervised Task and is killed on expiry
    * any other key is passed to the step as its opts
  """

  @control_keys [:name, :when, :on_error, :retry, :timeout]

  defstruct [:kind, :name, :impl, opts: [], when: nil, on_error: :halt, retry: 0, timeout: nil]

  @type t :: %__MODULE__{
          kind: :module | :function | :parallel,
          name: term(),
          impl: module() | function() | [t()],
          opts: term(),
          when: nil | atom() | (term() -> boolean()),
          on_error: :halt | :continue | {:recover, function()},
          retry: non_neg_integer(),
          timeout: nil | pos_integer()
        }

  def normalize(%__MODULE__{} = spec), do: spec
  def normalize({:parallel, branches, opts}), do: parallel(branches, opts)
  def normalize({impl, opts}) when is_list(opts), do: build(impl, opts)
  def normalize(impl), do: build(impl, [])

  def parallel(branches, opts) do
    {control, _} = Keyword.split(opts, @control_keys)

    struct!(
      __MODULE__,
      [kind: :parallel, impl: Enum.map(branches, &normalize/1), name: control[:name] || :parallel] ++
        Keyword.delete(control, :name)
    )
  end

  defp build(impl, opts) do
    {control, step_opts} = Keyword.split(opts, @control_keys)

    kind =
      cond do
        is_function(impl, 2) -> :function
        is_atom(impl) -> :module
        true -> raise ArgumentError, "invalid pipeline step: #{inspect(impl)}"
      end

    if kind == :function and is_nil(control[:name]) do
      raise ArgumentError, "anonymous function steps need a :name"
    end

    step_opts =
      if kind == :module and Code.ensure_loaded?(impl) and function_exported?(impl, :init, 1),
        do: impl.init(step_opts),
        else: step_opts

    struct!(
      __MODULE__,
      [kind: kind, impl: impl, opts: step_opts, name: control[:name] || impl] ++
        Keyword.delete(control, :name)
    )
  end
end
