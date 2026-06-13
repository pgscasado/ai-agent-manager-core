defmodule AgentManagerWeb.Router do
  use AgentManagerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end
end
