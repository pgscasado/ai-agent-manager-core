defmodule AgentManagerWeb.BotController do
  use AgentManagerWeb, :controller

  alias AgentManager.{Bots, Knowledge, Models, Training}
  alias AgentManager.Pipeline.Context
  alias AgentManager.Pipelines.Answer.Helpers
  alias AgentManagerWeb.{BotJSON, Params}

  action_fallback AgentManagerWeb.FallbackController

  @doc "Creates a bot and, when it comes with content, starts training it."
  def create(conn, params) do
    params = Map.drop(params, ["id", "timestamp"])

    with {:ok, bot} <- Bots.create(params) do
      {bot, status} =
        case content_params(params) do
          nil ->
            {bot, nil}

          content ->
            case Training.request(bot, content, overload: overload?(conn)) do
              {:ok, bot} -> {bot, "ON_TRAINING"}
              {:error, _} -> {bot, "FAILED"}
            end
        end

      conn |> put_status(200) |> json(bot |> BotJSON.show() |> Map.put(:training_status, status))
    end
  end

  def index(conn, params) do
    size = parse_int(params["size"], 5)
    {total, bots} = Bots.list(params["cursor"], size)

    json(conn, %{
      total_documents: total,
      total_pages: if(total == 0, do: 0, else: ceil(total / size)),
      next_cursor: bots |> List.last() |> then(&(&1 && &1.id)),
      bots:
        Enum.map(
          bots,
          &%{
            id: &1.id,
            identifier: &1.identifier,
            training_info: %{status: &1.training_info && &1.training_info.status}
          }
        )
    })
  end

  def training_status(conn, %{"ids" => ids}) when is_list(ids) do
    json(
      conn,
      Enum.map(Bots.get_many(ids), fn bot ->
        info = bot.training_info

        %{
          id: bot.id,
          status: (info && info.status) || :FINISHED,
          message_error: Enum.join((info && info.error_messages) || [], "\n")
        }
      end)
    )
  end

  def training_status(_conn, _params), do: {:error, {:bad_request, "ids must be a list"}}

  def show(conn, %{"id" => id}) do
    with {:ok, bot} <- Bots.fetch(id), do: json(conn, BotJSON.show(bot))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.update(bot, Map.drop(params, ["id", "timestamp"])) do
      json(conn, BotJSON.show(bot))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.delete(bot),
         do: json(conn, BotJSON.show(bot))
  end

  def top_k(conn, %{"id" => id} = params) do
    with {:ok, [text]} <- Params.require(params, ["text"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, hits} <- Knowledge.search(bot, text, 5) do
      json(conn, %{text: text, topK: hits})
    end
  end

  @doc "Starts (re)training with new content. Returns immediately; follow `training.*` events."
  def update_prompt(conn, %{"id" => id} = params) do
    content = Map.drop(params, ["id"])

    with {:ok, bot} <- Bots.fetch(id),
         {:ok, _bot} <- Training.request(bot, content, overload: overload?(conn)) do
      json(conn, %{message: "Training started"})
    end
  end

  def prompt_token_limit(conn, %{"id" => id}) do
    with {:ok, bot} <- Bots.fetch(id) do
      json(conn, %{prompt_quota: floor(0.3 * Models.token_budget(Bots.chat_model(bot)))})
    end
  end

  def paraphrase(conn, %{"id" => id} = params) do
    with {:ok, [text]} <- Params.require(params, ["text"]),
         {:ok, bot} <- Bots.fetch(id) do
      {result, _ctx} = Helpers.paraphrase(Context.new(%{text: text}, bot: bot), text)
      json(conn, %{paraphrase: result})
    end
  end

  @doc """
  Swaps models: any of `llm_model`, `utility_model`, `embedding_model` (specs
  like `"anthropic:claude-opus-5"`) and `api_keys` (`%{"anthropic" => "..."}`).
  Changing `embedding_model` requires retraining the bot.
  """
  def update_models(conn, %{"id" => id} = params) do
    changes =
      Map.take(params, [
        "llm_model",
        "utility_model",
        "embedding_model",
        "api_keys",
        "temperature",
        "message_buffer",
        "tools"
      ])

    with :ok <- validate_specs(changes),
         :ok <- validate_tools(changes["tools"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.update(bot, %{"model_config" => changes}) do
      json(conn, BotJSON.show(bot))
    end
  end

  @doc """
  Sets the tools a bot may call: ids or globs, e.g.
  `{"tools": ["local:current_time", "mcp:crm/*"]}`. `[]` disables tools.
  See `GET /tools` for what is available.
  """
  def update_tools(conn, %{"id" => id} = params) do
    with :ok <- validate_tools(params["tools"]),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.update(bot, %{"model_config" => %{"tools" => params["tools"]}}) do
      json(conn, %{
        tools: bot.model_config.tools,
        resolved: Enum.map(AgentManager.Tools.for_bot(bot), & &1.id)
      })
    end
  end

  defp validate_tools(nil), do: :ok

  defp validate_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1),
      do: :ok,
      else: {:error, {:bad_request, "tools must be a list of strings"}}
  end

  defp validate_tools(_), do: {:error, {:bad_request, "tools must be a list of strings"}}

  def patch_model_field(conn, %{"id" => id, "value" => value}) do
    field = conn.private.field

    with :ok <- if(field == :llm_model, do: validate_specs(%{"llm_model" => value}), else: :ok),
         {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.patch_model_field(bot, field, value) do
      json(conn, BotJSON.show(bot))
    end
  end

  def patch_field(conn, %{"id" => id, "value" => value} = params) do
    extra = Map.take(params, ["access_control_message"])

    with {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.patch_field(bot, conn.private.field, value, extra) do
      json(conn, BotJSON.show(bot))
    end
  end

  def job_timings(conn, %{"id" => id} = params) do
    with {:ok, bot} <- Bots.fetch(id),
         {:ok, bot} <- Bots.set_job_timings(bot, params["inactive"], params["nps"]) do
      json(conn, BotJSON.show(bot))
    end
  end

  defp validate_specs(changes) do
    changes
    |> Map.take(["llm_model", "utility_model", "embedding_model"])
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Enum.find_value(:ok, fn {field, spec} ->
      kind = if field == "embedding_model", do: :embedding, else: :chat

      case Models.resolve(spec, kind) do
        {:ok, _} -> nil
        error -> error
      end
    end)
  end

  defp content_params(params) do
    get_in(params, ["openai_config", "temp_content"]) ||
      get_in(params, ["model_config", "content"])
  end

  defp overload?(conn) do
    System.get_env("ALWAYS_OVERLOAD_TRAINING") == "true" or
      conn.query_params["overload"] == "true"
  end

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) do
    case Integer.parse(to_string(v)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
