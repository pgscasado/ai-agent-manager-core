defmodule AgentManager.Models do
  @moduledoc """
  Single entry point for every model call in the system.

  Models are addressed by a **spec string**, `"provider:model"`:

      "openai:gpt-4o"
      "anthropic:claude-opus-5"
      "ollama:llama3.1"
      "fake:echo"

  Providers are declared in config, so adding one (an OpenAI-compatible
  gateway, a second Ollama host, a local Bumblebee serving) is configuration,
  not code:

      config :agent_manager, AgentManager.Models,
        providers: [
          openai: [adapter: AgentManager.Models.Adapters.OpenAI, api_key: "..."],
          groq: [adapter: AgentManager.Models.Adapters.OpenAI, base_url: "https://api.groq.com/openai/v1"],
          anthropic: [adapter: AgentManager.Models.Adapters.Anthropic, api_key: "..."]
        ],
        aliases: %{"gpt-3.5-turbo" => "openai:gpt-4o-mini"},
        defaults: [chat: "openai:gpt-4o-mini", utility: nil, embedding: "openai:text-embedding-3-small"],
        budgets: %{"openai:gpt-4o" => 12_000}

  A bot swaps models by changing `model_config.llm_model` to another spec; no
  code or deploy is involved. Legacy bare names (`"gpt-4o"`) resolve through
  `:aliases`, then fall back to the default chat provider.

  Every call is timed and published as an `llm.completed` / `llm.failed`
  event (the `UsageRecorder` handler persists them), plus telemetry under
  `[:agent_manager, :models, :chat | :embed]`.
  """

  alias AgentManager.Events

  defmodule Resolved do
    @moduledoc false
    defstruct [:spec, :provider, :name, :adapter, opts: []]
  end

  @default_budget 8_000

  # -- resolution --------------------------------------------------------

  @doc "Resolves a spec (or alias, or `nil` for the default of `kind`)."
  @spec resolve(String.t() | nil, :chat | :utility | :embedding) ::
          {:ok, %Resolved{}} | {:error, term()}
  def resolve(spec, kind \\ :chat)
  def resolve(nil, :utility), do: resolve(default(:utility) || default(:chat), :chat)
  def resolve(nil, kind), do: resolve(default(kind), kind)
  def resolve("", kind), do: resolve(nil, kind)

  def resolve(spec, kind) when is_binary(spec) do
    spec = Map.get(config(:aliases, %{}), spec, spec)

    {provider, name} =
      case String.split(spec, ":", parts: 2) do
        [provider, name] -> {provider, name}
        [name] -> {default_provider(kind), name}
      end

    providers = config(:providers, [])

    case Enum.find(providers, fn {key, _} -> to_string(key) == provider end) do
      {_key, provider_opts} ->
        {adapter, opts} = Keyword.pop!(provider_opts, :adapter)

        {:ok,
         %Resolved{
           spec: provider <> ":" <> name,
           provider: provider,
           name: name,
           adapter: adapter,
           opts: Keyword.put(opts, :model, name)
         }}

      nil ->
        {:error, {:unknown_provider, provider}}
    end
  end

  def default(kind), do: Keyword.get(config(:defaults, []), kind)

  defp default_provider(kind) do
    (default(kind) || default(:chat) || "openai:") |> String.split(":") |> hd()
  end

  @doc "Tokens the prompt (instructions + context + history) may use for `spec`."
  def token_budget(spec) do
    budgets = config(:budgets, %{})

    case resolve(spec) do
      {:ok, r} ->
        Map.get(budgets, r.spec) || Map.get(budgets, spec) ||
          Map.get(budgets, r.provider, @default_budget)

      _ ->
        Map.get(budgets, spec, @default_budget)
    end
  end

  @doc "Lists every configured provider with its adapter."
  def providers,
    do: Enum.map(config(:providers, []), fn {k, v} -> {to_string(k), v[:adapter]} end)

  # -- calls ---------------------------------------------------------------

  @doc """
  Sends `messages` to the chat model named by `spec`.

  Extra opts: `:api_keys` (map of provider => key; the matching one wins over
  provider config), `:bot_id` and `:correlation_id` (for events), plus any
  `ChatModel` option.
  """
  def chat(spec, messages, opts \\ []) do
    with {:ok, r} <- resolve(spec, opts[:kind] || :chat) do
      call_opts = merge_opts(r, opts)
      meta = %{spec: r.spec, provider: r.provider}

      {latency_us, result} =
        :timer.tc(fn ->
          :telemetry.span([:agent_manager, :models, :chat], meta, fn ->
            result = r.adapter.chat(messages, call_opts)
            {result, Map.put(meta, :status, elem(result, 0))}
          end)
        end)

      report(r, result, div(latency_us, 1000), call_opts, opts)
      result
    end
  end

  @doc "Embeds `texts` with the embedding model named by `spec` (default if nil)."
  def embed(spec, texts, opts \\ []) when is_list(texts) do
    with {:ok, r} <- resolve(spec, :embedding) do
      meta = %{spec: r.spec, provider: r.provider, count: length(texts)}

      :telemetry.span([:agent_manager, :models, :embed], meta, fn ->
        result = r.adapter.embed(texts, merge_opts(r, opts))
        {result, Map.put(meta, :status, elem(result, 0))}
      end)
    end
  end

  @doc "Spec string a bot's embeddings are stored under (resolved, so aliases match)."
  def embedding_spec(spec) do
    case resolve(spec, :embedding) do
      {:ok, r} -> r.spec
      _ -> spec
    end
  end

  defp merge_opts(%Resolved{} = r, opts) do
    key =
      get_in(opts, [:api_keys, r.provider]) ||
        get_in(opts, [:api_keys, String.to_atom(r.provider)])

    r.opts
    |> Keyword.merge(Keyword.drop(opts, [:api_keys, :bot_id, :correlation_id, :kind]))
    |> then(fn o -> if key in [nil, ""], do: o, else: Keyword.put(o, :api_key, key) end)
    |> Keyword.put(:model, r.name)
  end

  defp report(r, {:ok, response}, latency_ms, call_opts, opts) do
    Events.publish(
      "llm.completed",
      %{
        model: r.spec,
        usage: response.usage,
        latency_ms: latency_ms,
        key_hint: key_hint(call_opts[:api_key])
      },
      bot_id: opts[:bot_id],
      correlation_id: opts[:correlation_id]
    )
  end

  defp report(r, {:error, reason}, latency_ms, _call_opts, opts) do
    Events.publish(
      "llm.failed",
      %{model: r.spec, reason: inspect(reason), latency_ms: latency_ms},
      bot_id: opts[:bot_id],
      correlation_id: opts[:correlation_id]
    )
  end

  defp key_hint(nil), do: nil

  defp key_hint(key) when byte_size(key) > 10,
    do: String.slice(key, 0, 5) <> "..." <> String.slice(key, -5, 5)

  defp key_hint(_), do: "***"

  defp config(key, default) do
    :agent_manager |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default) |> expand()
  end

  defp expand(providers) when is_list(providers) do
    Enum.map(providers, fn
      {k, opts} when is_list(opts) -> {k, Enum.map(opts, fn {ok, ov} -> {ok, env(ov)} end)}
      other -> other
    end)
  end

  defp expand(other), do: other

  defp env({:system, var}), do: System.get_env(var)
  defp env(value), do: value
end
