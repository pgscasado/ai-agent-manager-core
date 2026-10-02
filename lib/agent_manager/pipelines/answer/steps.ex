defmodule AgentManager.Pipelines.Answer.Steps do
  @moduledoc "Steps of `AgentManager.Pipelines.Answer`, one module each."

  @end_question "Podemos ajudar ainda de alguma forma?"
  def end_question, do: @end_question

  defmodule RunCommands do
    @moduledoc "Intercepts chat commands; halts with their reply."
    use AgentManager.Pipeline.Step
    alias AgentManager.{Answer, Commands}

    @impl true
    def call(ctx, _opts) do
      case Commands.find(ctx.input.text) do
        nil ->
          {:ok, ctx}

        command ->
          {:reply, text, effects} = command.run(ctx.input.text, ctx)
          ctx = Context.assign(ctx, effects: effects, skip_persist: true)
          {:halt, Context.halt(ctx, Answer.new(text))}
      end
    end
  end

  defmodule CheckDisabled do
    @moduledoc "A disabled bot hands every message to human attendance."
    use AgentManager.Pipeline.Step
    alias AgentManager.Answer

    @impl true
    def call(%{bot: %{disabled: true}} = ctx, _opts),
      do: {:halt, Context.halt(ctx, Answer.disabled())}

    def call(ctx, _opts), do: {:ok, ctx}
  end

  defmodule PrepareHistory do
    @moduledoc """
    Builds the conversation window: drops messages older than
    `user_history_time` minutes and answers flagged `missing_info` (unless the
    bot's `drop_missing_info_history` is off), collapses consecutive identical
    answers, and keeps the last `message_buffer` turns. Also derives the flags
    that gate the follow-up steps.
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.Pipelines.Answer.Steps

    @impl true
    def call(%{bot: bot} = ctx, _opts) do
      buffer = (bot.model_config && bot.model_config.message_buffer) || 2

      drop_missing_info? =
        !bot.model_config or bot.model_config.drop_missing_info_history != false

      since =
        if bot.user_history_time in [nil, 0],
          do: nil,
          else: DateTime.add(DateTime.utc_now(), -bot.user_history_time * 60, :second)

      history =
        (ctx.input[:history] || [])
        |> Enum.filter(&(is_nil(since) or DateTime.compare(&1.inserted_at, since) != :lt))
        |> Enum.reject(
          &(drop_missing_info? and
              get_in(&1.response || %{}, ["metadata", "missing_info"]) in [true, "true"])
        )
        |> Enum.dedup_by(&response_text/1)
        |> Enum.take(-(buffer * 4))

      chat_history =
        history
        |> Enum.flat_map(fn msg ->
          user = if msg.message, do: [%{role: :user, content: msg.message}], else: []

          bot_reply =
            if msg.response,
              do: [%{role: :assistant, content: Jason.encode!(msg.response)}],
              else: []

          user ++ bot_reply
        end)
        |> Enum.take(-(buffer * 2))

      sample =
        history
        |> Enum.flat_map(&[&1.message, response_text(&1)])
        |> Enum.reject(&is_nil/1)
        |> Kernel.++([ctx.input.text])
        |> Enum.join(" ")

      last = List.last(history)
      last_response = last && last.response

      {:ok,
       Context.assign(ctx,
         history: history,
         chat_history: chat_history,
         language_sample: sample,
         last_response: last_response,
         asked_if_more_help: String.ends_with?(response_text(last) || "", Steps.end_question()),
         offered_attendance:
           !bot.direct_attendance and
             truthy?(last_response && last_response["asked_for_attendance"])
       )}
    end

    defp response_text(nil), do: nil
    defp response_text(%{response: %{"response" => text}}), do: text
    defp response_text(_), do: nil

    defp truthy?(v), do: v in [true, "true"]
  end

  defmodule StartMessage do
    @moduledoc "First contact with a configured start message short-circuits the model."
    use AgentManager.Pipeline.Step
    alias AgentManager.Answer

    @impl true
    def call(%{bot: %{start_message: msg}} = ctx, _opts) when msg not in [nil, ""] do
      if Context.get(ctx, :history) == [],
        do: {:halt, Context.halt(ctx, Answer.new(msg))},
        else: {:ok, ctx}
    end

    def call(ctx, _opts), do: {:ok, ctx}
  end

  defmodule DetectLanguage do
    @moduledoc "Narrows the bot's allowed languages to the one the user is writing in."
    use AgentManager.Pipeline.Step
    alias AgentManager.Bots
    alias AgentManager.NLP.Language
    alias AgentManager.Pipelines.Answer.Helpers

    @impl true
    def call(ctx, _opts) do
      case Bots.allowed_languages(ctx.bot) do
        [] ->
          {:ok, Context.assign(ctx, languages: [], language_code: nil)}

        allowed ->
          opts = [llm: ctx.bot.gpt_language_detector] ++ Helpers.classifier_opts(ctx)
          code = Language.detect(Context.get(ctx, :language_sample, ctx.input.text), opts)

          {:ok,
           Context.assign(ctx, languages: Language.narrow(allowed, code), language_code: code)}
      end
    end
  end

  defmodule RetrieveContext do
    @moduledoc """
    Vector search, then keeps as many segments as fit the model's prompt
    budget (minus the conversation window), with a floor of `:min_segments`.
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.{Bots, Knowledge, Models, Prompts}
    alias AgentManager.NLP.Tokenizer

    @impl true
    def call(ctx, opts) do
      bot = ctx.bot

      case Knowledge.search(bot, ctx.input.text, opts[:k] || 100, Context.model_opts(ctx)) do
        {:ok, hits} ->
          budget =
            Models.token_budget(Bots.chat_model(bot)) -
              Tokenizer.count_messages(Context.get(ctx, :chat_history, []))

          fixed = Tokenizer.count(Prompts.system(bot, "")) + Tokenizer.count(ctx.input.text) + 300

          {fitted, _} =
            Enum.reduce_while(hits, {[], fixed}, fn hit, {acc, used} ->
              cost = Tokenizer.count(hit.segment) + 2

              if used + cost > budget,
                do: {:halt, {acc, used}},
                else: {:cont, {[hit | acc], used + cost}}
            end)

          fitted = Enum.reverse(fitted)
          min = opts[:min_segments] || 5
          segments = if length(fitted) < min, do: Enum.take(hits, min), else: fitted

          {:ok, Context.assign(ctx, segments: segments)}

        {:error, reason} ->
          # No knowledge is not fatal: the model is told it has no information.
          Logger.warning("[answer] retrieval failed: #{inspect(reason)}")
          {:ok, Context.assign(ctx, segments: []) |> Context.add_error({:retrieval, reason})}
      end
    end
  end

  defmodule InactivityFollowUp do
    @moduledoc """
    After "Podemos ajudar ainda de alguma forma?": a negative reply ends the
    conversation, "sim" re-opens it, anything else is answered normally
    (without the closing question in the window).
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.{Answer, Prompts}
    alias AgentManager.Pipelines.Answer.Helpers

    @closing "Certo, vou finalizar a nossa conversa, mas se precisar de mais alguma ajuda, é só chamar novamente! Agradeço pelo contato!"

    @impl true
    def call(ctx, _opts) do
      text = ctx.input.text

      with {:ok, verdict, ctx} <-
             Helpers.utility(ctx, [%{role: :user, content: Prompts.inactivity_refusal(text)}]) do
        cond do
          verdict |> String.downcase() |> String.contains?("true") ->
            {closing, ctx} =
              Helpers.paraphrase(ctx, System.get_env("POST_INACTIVITY_MESSAGE") || @closing)

            {:halt,
             Context.halt(ctx, Answer.new(closing, metadata: %{is_end_of_conversation: true}))}

          String.downcase(String.trim(text)) == "sim" ->
            {:halt, Context.halt(ctx, Answer.new("Certo! Como ainda posso te ajudar?"))}

          true ->
            {:ok,
             Context.assign(ctx, chat_history: Enum.drop(Context.get(ctx, :chat_history, []), -1))}
        end
      end
    end
  end

  defmodule AttendanceConfirmation do
    @moduledoc "The bot offered a human last turn: read yes/no and hand off or continue."
    use AgentManager.Pipeline.Step
    alias AgentManager.{Answer, Prompts}
    alias AgentManager.NLP.Sentiment
    alias AgentManager.Pipelines.Answer.Helpers

    @impl true
    def call(ctx, _opts) do
      last = get_in(Context.get(ctx, :last_response) || %{}, ["response"]) || ""

      last_sentence =
        last |> String.split(".") |> Enum.reject(&(String.trim(&1) == "")) |> List.last() || last

      prompt = Prompts.attendance_intent(last_sentence, ctx.input.text)

      positive =
        Task.async(fn -> Sentiment.positive?(ctx.input.text, Helpers.classifier_opts(ctx)) end)

      case Helpers.utility(ctx, [%{role: :user, content: prompt}], json: true) do
        {:ok, raw, ctx} ->
          intent = raw |> AgentManager.JSON.decode_object() |> intent()

          cond do
            String.contains?(intent, "affi") or Task.await(positive, 30_000) ->
              {text, ctx} =
                Helpers.paraphrase(
                  ctx,
                  "Um consultor irá entrar em contato com você em breve. Obrigado por entrar em contato conosco."
                )

              {:halt,
               Context.halt(
                 ctx,
                 Answer.new(text,
                   start_attendance: true,
                   metadata: %{is_end_of_conversation: true}
                 )
               )}

            String.contains?(intent, "nega") ->
              {text, ctx} =
                Helpers.paraphrase(ctx, "Tudo bem, iremos continuar com o atendimento virtual.")

              {:halt, Context.halt(ctx, Answer.new(text))}

            true ->
              {:ok, ctx}
          end

        {:error, reason, ctx} ->
          Task.shutdown(positive, :brutal_kill)
          {:error, reason, ctx}
      end
    end

    defp intent({:ok, %{"response" => r}}) when is_binary(r), do: String.downcase(r)
    defp intent(_), do: "undefined"
  end

  defmodule BuildPrompt do
    @moduledoc "Assembles the chat messages: system prompt, format rules, history, question."
    use AgentManager.Pipeline.Step
    alias AgentManager.{Attachments, Prompts}

    @impl true
    def call(ctx, _opts) do
      bot = ctx.bot

      context_text =
        case Context.get(ctx, :segments, []) do
          [] -> Prompts.no_info()
          segments -> Enum.map_join(segments, "\n---\n", &Attachments.mask(&1.segment))
        end

      # who is talking, when the channel knows (e.g. a WhatsApp profile name)
      user_line =
        case ctx.input[:user_name] do
          name when is_binary(name) and name != "" -> "\nThe user's name is #{name}."
          _ -> ""
        end

      messages =
        [
          %{role: :system, content: Prompts.system(bot, context_text) <> user_line},
          %{
            role: :system,
            content:
              Prompts.json_format(
                Context.get(ctx, :languages, []),
                bot.has_attendance,
                bot.direct_attendance
              )
          }
        ] ++ Context.get(ctx, :chat_history, []) ++ [%{role: :user, content: ctx.input.text}]

      {:ok, Context.assign(ctx, messages: messages)}
    end
  end

  defmodule Generate do
    @moduledoc """
    Calls the bot's model in JSON mode and parses the answer object.

    When the bot has tools (`model_config.tools`), this runs the tool loop:
    the model may ask for tools, they run concurrently, their results go back
    to the model, and so on - up to `:max_tool_rounds` rounds, after which the
    model is told to answer with what it has. Each call publishes
    `tool.called` / `tool.completed`.
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.{Answer, Tools}
    alias AgentManager.Pipelines.Answer.Helpers

    @default_rounds 5

    @impl true
    def call(ctx, opts) do
      specs = Tools.for_bot(ctx.bot)
      rounds = opts[:max_tool_rounds] || @default_rounds

      with {:ok, content, ctx} <- loop(ctx, Context.get(ctx, :messages), specs, rounds) do
        case AgentManager.JSON.decode_object(content) do
          {:ok, %{"response" => response} = parsed} when is_binary(response) ->
            {:ok, Context.assign(ctx, parsed: parsed)}

          _ ->
            # A model that ignores the format still produced an answer; use it.
            {:ok, Context.assign(ctx, parsed: %{"response" => String.trim(content)})}
        end
      end
    end

    defp loop(ctx, messages, [], _rounds) do
      Helpers.chat(ctx, messages, json: true)
    end

    defp loop(ctx, messages, specs, rounds_left) do
      tools = Tools.definitions(specs)

      messages =
        if rounds_left == 0,
          do:
            messages ++
              [
                %{
                  role: :system,
                  content:
                    "Tool budget exhausted: do not call tools again. Answer now with the information you have."
                }
              ],
          else: messages

      with {:ok, response, ctx} <-
             Helpers.chat(ctx, messages, json: true, tools: tools, full: true) do
        case response.tool_calls do
          [] ->
            {:ok, response.content, ctx}

          _calls when rounds_left == 0 ->
            {:error, :tool_rounds_exhausted, ctx}

          calls ->
            {results, ctx} = run_tools(ctx, calls, specs)

            messages =
              messages ++
                [%{role: :assistant, content: response.content, tool_calls: calls}] ++
                Enum.map(results, fn r ->
                  %{
                    role: :tool,
                    tool_call_id: r.call.id,
                    name: r.call.name,
                    content: r.content,
                    is_error: r.is_error
                  }
                end)

            loop(ctx, messages, specs, rounds_left - 1)
        end
      end
    end

    defp run_tools(ctx, calls, specs) do
      for call <- calls,
          do: Context.publish(ctx, "tool.called", %{tool: call.name, arguments: call.arguments})

      results = Tools.execute_all(calls, specs, ctx)

      for r <- results do
        Context.publish(ctx, "tool.completed", %{
          tool: r.call.name,
          id: r.spec && r.spec.id,
          is_error: r.is_error,
          duration_ms: r.duration_ms,
          # a preview, for traces and dashboards
          result: String.slice(to_string(r.content), 0, 500)
        })
      end

      used = Enum.map(results, &((&1.spec && &1.spec.id) || &1.call.name))
      {results, Context.assign(ctx, :tools_used, Context.get(ctx, :tools_used, []) ++ used)}
    end

    @doc "Used as `on_error: {:recover, ...}`: apologise and hand off to a human."
    def recover(ctx, reason) do
      Logger.error("[answer] generation failed: #{inspect(reason)}")
      {text, ctx} = Helpers.paraphrase(ctx, Answer.technical_problem_text())
      Context.halt(ctx, Answer.new(text, start_attendance: true, error: true))
    end
  end

  defmodule ResolveAttachments do
    @moduledoc """
    Attachments come from `ANEXO(url)` markers in the answer or, failing that,
    from the retrieved row whose `[attachment]` column the model picks.
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.{Attachments, Prompts}
    alias AgentManager.Pipelines.Answer.Helpers

    @impl true
    def call(ctx, _opts) do
      response = Context.get(ctx, :parsed)["response"]
      explicit = Attachments.extract_from_response(response)

      candidates =
        ctx |> Context.get(:segments, []) |> Enum.filter(&Attachments.has_attachment?/1)

      {urls, ctx} =
        cond do
          explicit != [] -> {explicit, ctx}
          candidates == [] -> {[], ctx}
          true -> choose(ctx, candidates, response)
        end

      attachments = Enum.map(urls, &%{url: &1, extension: Attachments.extension(&1)})
      {:ok, Context.assign(ctx, attachments: attachments)}
    end

    defp choose(ctx, candidates, response) do
      prompt =
        Prompts.choose_attachment("User: #{ctx.input.text} -> Bot: #{response}", candidates)

      with {:ok, answer, ctx} <- Helpers.utility(ctx, [%{role: :user, content: prompt}]),
           [n] <- Regex.run(~r/-?\d+/, answer),
           index when index > 0 <- String.to_integer(n),
           %{} = segment <- Enum.at(candidates, index - 1),
           url when is_binary(url) <- Attachments.field(segment) do
        {[url], ctx}
      else
        {:error, _reason, ctx} -> {[], ctx}
        _ -> {[], ctx}
      end
    end
  end

  defmodule ShapeAnswer do
    @moduledoc "Applies the attendance rules to the parsed model output."
    use AgentManager.Pipeline.Step
    alias AgentManager.Answer
    alias AgentManager.Pipelines.Answer.Helpers

    @queue_note " Você está na fila e será atendido(a) em instantes."
    @handoff_words ~w(direcionando aguarde atendimento humano)

    @impl true
    def call(ctx, _opts) do
      bot = ctx.bot
      parsed = Context.get(ctx, :parsed)
      attachments = Context.get(ctx, :attachments, [])
      offer = truthy?(parsed["offer_human_attendance"])
      start = truthy?(parsed["start_attendance"])
      greeting = truthy?(parsed["is_greeting_response"])

      answer =
        Answer.new(parsed["response"],
          type: if(attachments == [], do: :default, else: :attachment),
          attachments: attachments,
          metadata: %{
            yes_or_no: truthy?(parsed["yes_or_no_question"] || parsed["yes_or_no"]),
            missing_info: truthy?(parsed["missing_info"]),
            is_greeting: greeting,
            is_bot_disabled: false
          }
        )

      {answer, ctx} =
        cond do
          bot.direct_attendance and (offer or start) ->
            response =
              if String.contains?(answer.response, @queue_note),
                do: answer.response,
                else: answer.response <> @queue_note

            {%{answer | start_attendance: true, asked_for_attendance: false, response: response},
             ctx}

          bot.direct_attendance ->
            {answer, ctx}

          true ->
            asked = offer and bot.has_attendance and (bot.attendance_on_greeting or not greeting)

            answer = %{
              answer
              | start_attendance: start and bot.has_attendance,
                asked_for_attendance: asked
            }

            ask_for_attendant(answer, ctx)
        end

      answer =
        case Context.get(ctx, :tools_used, []) do
          [] -> answer
          used -> %{answer | metadata: Map.put(answer.metadata, :tools_used, Enum.uniq(used))}
        end

      {:ok, Context.put_result(ctx, answer)}
    end

    defp ask_for_attendant(%{asked_for_attendance: true, response: response} = answer, ctx) do
      if String.ends_with?(String.trim(response), "?") do
        {answer, ctx}
      else
        {question, ctx} = Helpers.paraphrase(ctx, "Deseja falar com um atendente?")
        lower = String.downcase(response)

        if Enum.any?(@handoff_words, &String.contains?(lower, &1)),
          do: {%{answer | response: question}, ctx},
          else: {%{answer | response: response <> " " <> question}, ctx}
      end
    end

    defp ask_for_attendant(answer, ctx), do: {answer, ctx}

    defp truthy?(v), do: v in [true, "true"]
  end
end
