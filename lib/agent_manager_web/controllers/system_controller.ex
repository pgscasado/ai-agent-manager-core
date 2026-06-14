defmodule AgentManagerWeb.SystemController do
  @moduledoc "Introspection: configured model providers and the effective pipeline steps."
  use AgentManagerWeb, :controller

  alias AgentManager.{Models, Pipeline}
  alias AgentManager.Pipelines.{Answer, Training}

  def models(conn, _params) do
    json(conn, %{
      providers:
        Enum.map(Models.providers(), fn {name, adapter} ->
          %{name: name, adapter: inspect(adapter)}
        end),
      defaults: %{
        chat: Models.default(:chat),
        utility: Models.default(:utility),
        embedding: Models.default(:embedding)
      }
    })
  end

  def pipelines(conn, _params) do
    json(conn, %{answer: names(Answer.steps()), training: names(Training.steps())})
  end

  defp names(steps) do
    steps
    |> Pipeline.names()
    |> Enum.map(fn
      list when is_list(list) -> %{parallel: Enum.map(list, &inspect/1)}
      name -> inspect(name)
    end)
  end
end
