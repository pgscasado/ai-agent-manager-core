defmodule AgentManagerWeb.Params do
  @moduledoc "Minimal request validation helpers."

  @doc "Fetches non-empty string params, or `{:error, {:bad_request, msg}}`."
  def require(params, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case params[key] do
        v when is_binary(v) and v != "" -> {:cont, {:ok, acc ++ [v]}}
        _ -> {:halt, {:error, {:bad_request, "#{key} is required"}}}
      end
    end)
  end
end
