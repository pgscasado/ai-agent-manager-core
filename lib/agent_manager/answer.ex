defmodule AgentManager.Answer do
  @moduledoc """
  What a bot replies. Rendered in the 1.0 API shape (string booleans)
  by `AgentManagerWeb.AnswerJSON`.
  """

  @derive Jason.Encoder
  defstruct type: :default,
            response: "",
            start_attendance: false,
            asked_for_attendance: false,
            metadata: %{},
            attachments: [],
            error: false

  @type t :: %__MODULE__{
          type: :default | :attachment,
          response: String.t(),
          start_attendance: boolean(),
          asked_for_attendance: boolean(),
          metadata: map(),
          attachments: [%{url: String.t(), extension: String.t()}],
          error: boolean()
        }

  def new(response, fields \\ []), do: struct!(__MODULE__, [response: response] ++ fields)

  @technical_problem "Estamos com problemas técnicos, estou te direcionando ao atendimento humano."
  @disabled "Você está sendo direcionado para o atendimento, aguarde um momento."

  def technical_problem_text, do: @technical_problem

  def disabled do
    new(@disabled, start_attendance: true, metadata: %{is_bot_disabled: true})
  end

  @doc "Serialisable map, used for persistence in `messages.response`."
  def to_map(%__MODULE__{} = a) do
    %{
      "type" => to_string(a.type),
      "response" => a.response,
      "start_attendance" => a.start_attendance,
      "asked_for_attendance" => a.asked_for_attendance,
      "metadata" => Map.new(a.metadata, fn {k, v} -> {to_string(k), v} end),
      "attachments" =>
        Enum.map(a.attachments, fn att ->
          %{"url" => AgentManager.Attachments.mask(att.url), "extension" => att.extension}
        end)
    }
  end
end
