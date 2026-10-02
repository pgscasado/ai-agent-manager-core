defmodule AgentManagerWeb.UserSocket do
  use Phoenix.Socket

  channel "bot:*", AgentManagerWeb.BotChannel

  # Events carry message texts and user ids (WhatsApp numbers, for the
  # showcase), so once API_TOKEN is set the socket requires it as the
  # `token` connect param, like the HTTP API (with the same brute-force lockout).
  @impl true
  def connect(params, socket, connect_info) do
    ip = AgentManagerWeb.ClientIP.from_connect_info(connect_info)

    case AgentManagerWeb.Plugs.ApiAuth.check(params["token"], ip) do
      :ok -> {:ok, socket}
      :error -> :error
    end
  end

  @impl true
  def id(_socket), do: nil
end

defmodule AgentManagerWeb.BotChannel do
  @moduledoc """
  Live feed of one bot's events (`training.progress`, `message.answered`,
  `llm.completed`, ...). Join `"bot:<bot id>"`; each event is pushed with its
  type as the event name.
  """
  use AgentManagerWeb, :channel

  alias AgentManager.{Bots, Events}

  @impl true
  def join("bot:" <> bot_id, _params, socket) do
    case Bots.get(bot_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      bot ->
        :ok = Events.subscribe({:bot, bot.id})
        {:ok, assign(socket, :bot_id, bot.id)}
    end
  end

  @impl true
  def handle_info({:event, event}, socket) do
    push(socket, event.type, %{
      id: event.id,
      correlation_id: event.correlation_id,
      at: event.at,
      payload: sanitize(event.payload)
    })

    {:noreply, socket}
  end

  # Payloads may contain atoms/tuples (step names, error reasons); make them JSON-safe.
  defp sanitize(%DateTime{} = dt), do: dt
  defp sanitize(%_{} = struct), do: struct |> Map.from_struct() |> sanitize()
  defp sanitize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp sanitize(atom) when is_atom(atom) and atom not in [nil, true, false], do: inspect(atom)
  defp sanitize(other), do: other
end
