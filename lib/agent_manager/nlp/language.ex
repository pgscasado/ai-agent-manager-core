defmodule AgentManager.NLP.Language do
  @moduledoc """
  Language detection as a chain of detectors: the first one that returns a
  code wins.

      config :agent_manager, AgentManager.NLP.Language,
        detectors: [Greetings, Stopwords]   # default

  With `llm: true` (a bot's `gpt_language_detector` flag) the LLM detector is
  tried first. Add a local classifier by implementing `detect/2` and putting it
  in the chain.
  """

  alias AgentManager.NLP.Text

  @callback detect(String.t(), keyword()) :: {:ok, String.t()} | :unknown

  @external_resource codes_path =
                       Path.join(
                         :code.priv_dir(:agent_manager) |> to_string(),
                         "language/codes.json"
                       )
  @codes (case File.read(codes_path) do
            {:ok, json} -> Jason.decode!(json)
            _ -> %{"pt" => "portuguese", "en" => "english"}
          end)

  @aliases %{
    "pt" => ["portugu"],
    "en" => ["english", "ingles"],
    "es" => ["spanish", "espanol", "castellano", "espanhol"],
    "fr" => ["french", "francais", "frances"],
    "de" => ["german", "deutsch", "alemao"],
    "it" => ["italian", "italiano"]
  }

  def codes, do: @codes

  @doc "Detects the language code of `text` (e.g. `\"pt\"`); defaults to `\"pt\"`."
  def detect(text, opts \\ []) do
    detectors = if opts[:llm], do: [__MODULE__.LLM | chain()], else: chain()
    cleaned = strip_proper_nouns(text)

    Enum.find_value(detectors, "pt", fn detector ->
      case detector.detect(cleaned, opts) do
        {:ok, code} -> code
        :unknown -> nil
      end
    end)
  end

  defp chain do
    Application.get_env(:agent_manager, __MODULE__, [])[:detectors] ||
      [__MODULE__.Greetings, __MODULE__.Stopwords]
  end

  # Capitalised words that are not sentence-initial are likely names/places
  # and skew detection.
  defp strip_proper_nouns(text) do
    stripped = Regex.replace(~r/(?<=[\p{Ll},;]\s)\p{Lu}\p{L}+/u, text, "")
    if String.trim(stripped) == "", do: text, else: stripped
  end

  @doc "English name for a code, as used in `allowed_languages` (\"pt\" -> \"Portuguese\")."
  def name(code), do: @codes |> Map.get(code, code) |> String.capitalize()

  @doc """
  Narrows `allowed` (free-form names such as "Portuguese" or "Português
  brasileiro") to the one matching `code`, keeping all of them if none match.
  """
  def narrow(allowed, code) do
    needles = [Map.get(@codes, code, code) | Map.get(@aliases, code, [])]

    case Enum.find(allowed, fn lang ->
           Enum.any?(needles, &String.contains?(Text.normalize(lang), &1))
         end) do
      nil -> allowed
      found -> [found]
    end
  end

  defmodule Greetings do
    @moduledoc "Exact-match against greeting lists in `priv/language` (cheap, handles one-word messages)."
    @behaviour AgentManager.NLP.Language

    @dir Path.join(:code.priv_dir(:agent_manager) |> to_string(), "language")
    @files [
      {"pt", Path.join(@dir, "greetings_pt.json")},
      {"en", Path.join(@dir, "greetings_en.json")}
    ]

    for {_code, path} <- @files, do: @external_resource(path)

    @lists (for {code, path} <- @files, File.exists?(path) do
              {code, path |> File.read!() |> Jason.decode!() |> MapSet.new(&String.downcase/1)}
            end)

    @impl true
    def detect(text, _opts) do
      needle = text |> String.trim() |> String.trim_trailing("!") |> String.downcase()

      case Enum.find(@lists, fn {_code, set} -> MapSet.member?(set, needle) end) do
        {code, _} -> {:ok, code}
        nil -> :unknown
      end
    end
  end

  defmodule Stopwords do
    @moduledoc "Scores each language by the share of its stopwords in the text."
    @behaviour AgentManager.NLP.Language

    alias AgentManager.NLP.Text

    @sets Map.new(Text.stopwords(), fn {code, words} ->
            {code, MapSet.new(words, &Text.normalize/1)}
          end)

    @impl true
    def detect(text, _opts) do
      words = text |> Text.normalize() |> Text.words()

      scores =
        @sets
        |> Enum.map(fn {code, set} -> {code, Enum.count(words, &MapSet.member?(set, &1))} end)
        |> Enum.sort_by(&elem(&1, 1), :desc)

      case scores do
        [{_, 0} | _] -> :unknown
        [{code, a}, {_, b} | _] when a > b -> {:ok, code}
        # tie: prefer Portuguese, the primary audience
        [{_, a} | _] -> if Enum.any?(scores, &(&1 == {"pt", a})), do: {:ok, "pt"}, else: :unknown
      end
    end
  end

  defmodule LLM do
    @moduledoc "Asks the bot's utility model for an ISO 639-1 code (enabled per bot with `gpt_language_detector`)."
    @behaviour AgentManager.NLP.Language

    @impl true
    def detect(text, opts) do
      messages = [
        %{
          role: :user,
          content:
            "In what language is this phrase written: #{text}\n Only answer the ISO 639-1 language code. E.g. \"Language code: <code>\""
        }
      ]

      with {:ok, %{content: content}} <-
             AgentManager.Models.chat(
               opts[:model],
               messages,
               Keyword.merge(opts[:model_opts] || [], kind: :utility)
             ),
           code =
             content |> String.split(":") |> List.last() |> String.trim() |> String.downcase(),
           true <- Map.has_key?(AgentManager.NLP.Language.codes(), code) do
        {:ok, code}
      else
        _ -> :unknown
      end
    end
  end
end
