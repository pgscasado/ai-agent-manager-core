defmodule AgentManager.Events.Event do
  @moduledoc """
  The unit of communication between the parts of the system.

  Every interesting thing that happens (a message arrives, a model is called,
  training advances) is published as an event. Producers never know who is
  listening; consumers subscribe by type or by bot.

  `correlation_id` ties together every event caused by the same request, so a
  single answer can be traced across the pipeline, the model calls and the
  persistence handlers.
  """

  @enforce_keys [:id, :type, :at]
  defstruct [:id, :type, :bot_id, :correlation_id, :at, payload: %{}]

  @type type :: String.t()
  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          bot_id: String.t() | nil,
          correlation_id: String.t() | nil,
          at: DateTime.t(),
          payload: map()
        }

  @spec new(type(), map(), keyword()) :: t()
  def new(type, payload \\ %{}, opts \\ []) when is_binary(type) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      type: type,
      bot_id: opts[:bot_id],
      correlation_id: opts[:correlation_id],
      at: DateTime.utc_now(),
      payload: payload
    }
  end
end
