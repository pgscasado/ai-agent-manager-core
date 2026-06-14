defmodule AgentManagerWeb.FallbackController do
  @moduledoc "Maps context errors to HTTP responses."
  use AgentManagerWeb, :controller

  def call(conn, {:error, :not_found}), do: json_error(conn, 404, "Bot not found")
  def call(conn, {:error, :not_configured}), do: json_error(conn, 400, "Bot not configured")
  def call(conn, {:error, {:bad_request, message}}), do: json_error(conn, 400, message)

  def call(conn, {:error, :forbidden_field}),
    do:
      conn
      |> put_status(403)
      |> json(%{
        error: "UpdateForbiddenFieldError",
        message: "Trying to update invalid or forbidden field"
      })

  def call(conn, {:error, {:unknown_provider, provider}}),
    do: json_error(conn, 400, "Unknown model provider: #{provider}")

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(inspect(v)))
        end)
      end)

    conn |> put_status(400) |> json(%{message: "Invalid parameters", errors: errors})
  end

  def call(conn, {:error, reason}), do: json_error(conn, 500, inspect(reason))
  def call(conn, {:error, reason, _ctx}), do: json_error(conn, 500, inspect(reason))

  defp json_error(conn, status, message),
    do: conn |> put_status(status) |> json(%{message: message})
end
