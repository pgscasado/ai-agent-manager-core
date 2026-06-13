defmodule AgentManager.Commands do
  @moduledoc """
  Chat commands intercepted before the model is involved (e.g. `+limpar historico`).

  A command is any module implementing this behaviour; register it with

      config :agent_manager, AgentManager.Commands, commands: [ClearHistory, MyCommand]

  `run/2` returns the reply text plus optional *effects* - side effects on the
  conversation process (such as `:clear_history`) that the
  `Conversations.Server` applies after the pipeline finishes.
  """

  @callback match?(text :: String.t()) :: boolean()
  @callback run(text :: String.t(), ctx :: AgentManager.Pipeline.Context.t()) ::
              {:reply, String.t(), effects :: [atom()]}

  def all do
    Application.get_env(:agent_manager, __MODULE__, [])[:commands] || [__MODULE__.ClearHistory]
  end

  def find(text), do: Enum.find(all(), & &1.match?(text))

  defmodule ClearHistory do
    @moduledoc "`+limpar historico` - wipes the user's conversation history."
    @behaviour AgentManager.Commands

    @impl true
    def match?(text), do: text |> String.downcase() |> String.trim() == "+limpar historico"

    @impl true
    def run(_text, ctx) do
      AgentManager.Store.impl().delete_messages(ctx.bot.id, ctx.input.user_id)
      {:reply, "Limpei o histórico de mensagens!", [:clear_history]}
    end
  end
end
