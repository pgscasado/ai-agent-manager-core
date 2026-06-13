defmodule AgentManager.Pipelines.Answer.Helpers do
  @moduledoc "Model-call helpers shared by answer steps; they keep `ctx.usage` up to date."

  alias AgentManager.{Bots, Models, Prompts}
  alias AgentManager.Pipeline.Context
  alias AgentManager.NLP.Language

  @doc "Calls the bot's chat model (or `opts[:model]`), adding usage to the ctx."
  def chat(%Context{bot: bot} = ctx, messages, opts \\ []) do
    spec = Keyword.get_lazy(opts, :model, fn -> Bots.chat_model(bot) end)

    call_opts =
      [
        temperature: bot.model_config && bot.model_config.temperature,
        top_p: 0.5,
        max_tokens: if(bot.token_limit in [nil, 0], do: 750, else: bot.token_limit)
      ]
      |> Keyword.merge(Keyword.drop(opts, [:model]))
      |> Keyword.merge(Context.model_opts(ctx))

    case Models.chat(spec, messages, call_opts) do
      {:ok, response} -> {:ok, response.content, Context.add_usage(ctx, response.usage)}
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  @doc "Utility-model call (classification, rewriting)."
  def utility(ctx, messages, opts \\ []) do
    chat(ctx, messages, Keyword.merge([model: Bots.utility_model(ctx.bot), kind: :utility], opts))
  end

  @doc """
  Rewrites a canned text in the user's language.
  Falls back to the text itself when the model is unavailable.
  """
  def paraphrase(%Context{} = ctx, text) do
    languages = Context.get(ctx, :languages) || narrowed_languages(ctx)

    case utility(ctx, [%{role: :user, content: Prompts.paraphrase(text, languages)}], json: false) do
      {:ok, rewritten, ctx} when rewritten != "" -> {String.trim(rewritten), ctx}
      {:ok, _, ctx} -> {text, ctx}
      {:error, _, ctx} -> {text, ctx}
    end
  end

  defp narrowed_languages(ctx) do
    allowed = Bots.allowed_languages(ctx.bot)
    sample = Context.get(ctx, :language_sample) || ctx.input[:text] || ""
    if allowed == [], do: [], else: Language.narrow(allowed, Language.detect(sample))
  end

  @doc "Opts for language/sentiment classifiers that route through the utility model."
  def classifier_opts(ctx) do
    [model: Bots.utility_model(ctx.bot), model_opts: Context.model_opts(ctx)]
  end
end
