defmodule AgentManager.Pipelines.Training do
  @moduledoc """
  Turns a bot's content (text, file URLs, rules) into indexed segments.

  Input: `%{content: map(), overload: boolean()}` with `bot:` in the run opts.
  Output: `ctx.result` is `%{new_segments, deleted_segments, total_segments}`.

      ValidateRules -> InferStructure -> FetchSources -> Segment
        -> Diff -> Embed -> Index -> Finalize

  Fetching and embedding fan out across processes (`Task.async_stream`), and
  every stage reports `training.progress` events.
  """

  use AgentManager.Pipeline

  alias AgentManager.Pipelines.Training.Steps

  step(Steps.ValidateRules)
  step(Steps.InferStructure)
  step(Steps.FetchSources, concurrency: 4)
  step(Steps.Segment)
  step(Steps.Diff)
  step(Steps.Embed, batch_size: 64, concurrency: 4)
  step(Steps.Index)
  step(Steps.Finalize)
end

defmodule AgentManager.Pipelines.Training.Steps do
  @moduledoc "Steps of `AgentManager.Pipelines.Training`."

  alias AgentManager.Pipeline.Context

  # Stage weights for the overall percentage.
  @weights %{structure: 10, sources: 10, segmentation: 30, embedding: 50}

  @doc false
  def progress(ctx, stage, fraction) do
    done = Context.get(ctx, :progress, %{}) |> Map.put(stage, min(fraction, 1.0))

    percent =
      Enum.reduce(done, 0.0, fn {s, f}, acc -> acc + f * @weights[s] end) |> Float.round(2)

    Context.publish(ctx, "training.progress", %{stage: stage, percent: percent})
    Context.assign(ctx, :progress, done)
  end

  defmodule ValidateRules do
    @moduledoc "Behavioural rules may use at most 30% of the model's prompt budget (unless `overload`)."
    use AgentManager.Pipeline.Step
    alias AgentManager.{Bots, Models}
    alias AgentManager.NLP.Tokenizer

    @impl true
    def call(ctx, _opts) do
      limit = floor(0.3 * Models.token_budget(Bots.chat_model(ctx.bot)))
      tokens = Tokenizer.count(ctx.input.content["behavioral_rules"])

      if tokens > limit and not ctx.input[:overload],
        do:
          {:error,
           {:rules_too_long, "Behavioral rules too long. Please keep it under #{limit} tokens."},
           ctx},
        else: {:ok, ctx}
    end
  end

  defmodule InferStructure do
    @moduledoc """
    Derives settings from the content: attendance availability, languages
    (`[pt]`, `[*en]` tags in the rules, else detection, else Portuguese), and
    which sources are files.
    """
    use AgentManager.Pipeline.Step
    alias AgentManager.NLP.{Language, Text}
    alias AgentManager.Pipelines.Training.Steps

    @default_language "Português brasileiro"
    @url ~r/(?:^|\s)((?:https?|ftp):\/\/[^\s]+)/u

    @impl true
    def call(ctx, _opts) do
      content = ctx.input.content
      rules = content["behavioral_rules"] || ""
      normalized = Text.normalize(rules)

      tags = Regex.scan(~r/\[(\*?)([a-z]{2})(?:-[A-Z]{2})?\]/, rules, capture: :all_but_first)

      language =
        cond do
          tags != [] ->
            names = Enum.map(tags, fn [_, code] -> Language.name(code) end)

            default =
              Enum.find_value(tags, fn [star, code] -> star == "*" && Language.name(code) end)

            %{"allowed_languages" => Enum.uniq(names), "default_language" => default || hd(names)}

          String.length(normalized) > 15 ->
            name = Language.name(Language.detect(rules))
            %{"allowed_languages" => [name], "default_language" => name}

          true ->
            %{"allowed_languages" => [@default_language], "default_language" => @default_language}
        end

      {file_urls, page_urls} =
        Enum.split_with(content["source_urls"] || [], &String.ends_with?(&1, " file"))

      strip =
        &(&1
          |> String.trim()
          |> String.replace_suffix(" file", "")
          |> String.replace_suffix("file", ""))

      files = Enum.map((content["source_files"] || []) ++ file_urls, strip)

      text_urls =
        @url
        |> Regex.scan(content["source_text"] || "", capture: :all_but_first)
        |> List.flatten()

      content =
        Map.merge(content, %{
          "language" => language,
          "source_files" => Enum.uniq(files),
          "source_urls" => Enum.uniq(page_urls ++ text_urls)
        })

      ctx =
        ctx
        |> Context.assign(
          content: content,
          has_attendance: not String.contains?(normalized, "atendimento humano esta desabilitado")
        )
        |> Steps.progress(:structure, 1.0)

      {:ok, ctx}
    end
  end

  defmodule FetchSources do
    @moduledoc "Downloads and parses every source file concurrently; failures are recorded, not fatal."
    use AgentManager.Pipeline.Step
    alias AgentManager.Sources
    alias AgentManager.Pipelines.Training.Steps

    @impl true
    def call(ctx, opts) do
      content = Context.get(ctx, :content)
      files = content["source_files"]
      total = max(length(files), 1)

      {docs, errors, ctx} =
        files
        |> Task.async_stream(&{&1, Sources.fetch(&1)},
          max_concurrency: opts[:concurrency] || 4,
          timeout: 120_000,
          on_timeout: :kill_task
        )
        |> Stream.with_index(1)
        |> Enum.reduce({[], [], ctx}, fn
          {{:ok, {_url, {:ok, doc}}}, i}, {docs, errs, ctx} ->
            {[doc | docs], errs, Steps.progress(ctx, :sources, i / total)}

          {{:ok, {url, {:error, reason}}}, i}, {docs, errs, ctx} ->
            {docs, ["#{url}: #{inspect(reason)}" | errs],
             Steps.progress(ctx, :sources, i / total)}

          {{:exit, reason}, i}, {docs, errs, ctx} ->
            {docs, ["source timed out: #{inspect(reason)}" | errs],
             Steps.progress(ctx, :sources, i / total)}
        end)

      Enum.each(errors, &Logger.warning("[training] #{&1}"))
      ctx = Steps.progress(ctx, :sources, 1.0)

      {:ok,
       Context.assign(ctx,
         documents: Enum.reverse(docs) ++ [content["source_text"] || ""],
         source_errors: errors
       )}
    end
  end

  defmodule Segment do
    @moduledoc "Splits documents into segments, dropping duplicates and fragments of two words or fewer."
    use AgentManager.Pipeline.Step
    alias AgentManager.NLP.{Segmenter, Text}
    alias AgentManager.Pipelines.Training.Steps

    @impl true
    def call(ctx, _opts) do
      segments =
        ctx
        |> Context.get(:documents)
        |> Enum.flat_map(&Segmenter.segment/1)
        |> Enum.uniq()
        |> Enum.filter(&(length(Text.words(&1)) > 2))

      {:ok, ctx |> Context.assign(segments: segments) |> Steps.progress(:segmentation, 1.0)}
    end
  end

  defmodule Diff do
    @moduledoc "Keeps already-indexed segments (same text, same embedding model); only new ones get embedded."
    use AgentManager.Pipeline.Step
    alias AgentManager.{Bots, VectorStore}

    @impl true
    def call(ctx, _opts) do
      model = Bots.embedding_model(ctx.bot)
      wanted = Context.get(ctx, :segments)
      wanted_set = MapSet.new(wanted)

      existing =
        ctx.bot.id
        |> VectorStore.impl().list()
        |> Enum.filter(&(&1.embedding_model == model and MapSet.member?(wanted_set, &1.segment)))
        |> Enum.uniq_by(& &1.segment)

      known = MapSet.new(existing, & &1.segment)

      {:ok,
       Context.assign(ctx,
         embedding_model: model,
         keep_ids: Enum.map(existing, & &1.id),
         to_embed: Enum.reject(wanted, &MapSet.member?(known, &1))
       )}
    end
  end

  defmodule Embed do
    @moduledoc "Embeds new segments in batches, several batches in flight at once."
    use AgentManager.Pipeline.Step
    alias AgentManager.Models
    alias AgentManager.NLP.Text
    alias AgentManager.Pipelines.Training.Steps

    @impl true
    def call(ctx, opts) do
      model = Context.get(ctx, :embedding_model)
      segments = Context.get(ctx, :to_embed)
      batches = segments |> Enum.with_index() |> Enum.chunk_every(opts[:batch_size] || 64)
      total = max(length(batches), 1)
      model_opts = Context.model_opts(ctx)

      batches
      |> Task.async_stream(
        fn batch ->
          cleaned =
            Enum.map(batch, fn {seg, _} -> seg |> Text.remove_stopwords() |> String.downcase() end)

          with {:ok, vectors} <- Models.embed(model, cleaned, model_opts) do
            {:ok,
             Enum.zip_with([batch, cleaned, vectors], fn [{seg, i}, clean, vec] ->
               %{
                 segment: seg,
                 cleaned_segment: clean,
                 embedding: vec,
                 embedding_model: model,
                 index: i
               }
             end)}
          end
        end,
        max_concurrency: opts[:concurrency] || 4,
        timeout: 300_000
      )
      |> Stream.with_index(1)
      |> Enum.reduce_while({:ok, [], ctx}, fn
        {{:ok, {:ok, docs}}, i}, {:ok, acc, ctx} ->
          {:cont, {:ok, acc ++ docs, Steps.progress(ctx, :embedding, i / total)}}

        {{:ok, {:error, reason}}, _}, {:ok, _, ctx} ->
          {:halt, {:error, {:embedding_failed, reason}, ctx}}

        {{:exit, reason}, _}, {:ok, _, ctx} ->
          {:halt, {:error, {:embedding_failed, reason}, ctx}}
      end)
      |> case do
        {:ok, docs, ctx} ->
          {:ok, ctx |> Context.assign(embedded: docs) |> Steps.progress(:embedding, 1.0)}

        error ->
          error
      end
    end
  end

  defmodule Index do
    @moduledoc "Swaps the bot's index: stale segments out, new segments in."
    use AgentManager.Pipeline.Step
    alias AgentManager.VectorStore

    @impl true
    def call(ctx, _opts) do
      store = VectorStore.impl()

      {:ok, %{inserted: inserted, deleted: deleted}} =
        store.replace(ctx.bot.id, Context.get(ctx, :keep_ids), Context.get(ctx, :embedded))

      {:ok,
       Context.put_result(ctx, %{
         new_segments: inserted,
         deleted_segments: deleted,
         total_segments: store.count(ctx.bot.id)
       })}
    end
  end

  defmodule Finalize do
    @moduledoc "Saves the processed content and inferred settings on the bot."
    use AgentManager.Pipeline.Step
    alias AgentManager.Bots

    @impl true
    def call(ctx, _opts) do
      case Bots.update(ctx.bot, %{
             "has_attendance" => Context.get(ctx, :has_attendance),
             "model_config" => %{"content" => Context.get(ctx, :content)}
           }) do
        {:ok, bot} -> {:ok, %{ctx | bot: bot}}
        {:error, changeset} -> {:error, {:invalid_content, changeset.errors}, ctx}
      end
    end
  end
end
