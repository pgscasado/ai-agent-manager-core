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
    # a missing key fails here, before the budget or the network; the daily
    # budget is checked for every call, whoever makes it
    with {:ok, r} <- resolve(spec, opts[:kind] || :chat),
         call_opts = merge_opts(r, opts),
         :ok <- check_key(r, call_opts, opts),
         :ok <- AgentManager.Budget.reserve_call() do
      meta = %{spec: r.spec, provider: r.provider}

      {latency_us, result} =
        :timer.tc(fn ->
          :telemetry.span([:agent_manager, :models, :chat], meta, fn ->
            result = limited(r, call_opts, fn -> r.adapter.chat(messages, call_opts) end)
            {result, Map.put(meta, :status, elem(result, 0))}
          end)
        end)

      report(r, result, div(latency_us, 1000), call_opts, opts)
      AgentManager.Budget.record(result)
      result
    end
  end

  @doc "Embeds `texts` with the embedding model named by `spec` (default if nil)."
  def embed(spec, texts, opts \\ []) when is_list(texts) do
    with {:ok, r} <- resolve(spec, :embedding),
         call_opts = merge_opts(r, opts),
         :ok <- check_key(r, call_opts, opts) do
      meta = %{spec: r.spec, provider: r.provider, count: length(texts)}

      :telemetry.span([:agent_manager, :models, :embed], meta, fn ->
        result = limited(r, call_opts, fn -> r.adapter.embed(texts, call_opts) end)
        {result, Map.put(meta, :status, elem(result, 0))}
      end)
    end
  end

  # Providers configured with `rate_limit:` are paced by a RateLimiter, and
  # their 429/503 answers are retried here (after the provider's suggested
  # delay when it gives one) so that every attempt goes through the limiter.
  # Retrying stops when the next wait would exceed `max_wait` (ms, default
  # 30s) - a chat request must not hang for minutes - and never happens for
  # daily quotas, which a short wait cannot fix.
  defp limited(%Resolved{opts: provider_opts} = r, _call_opts, fun) do
    case provider_opts[:rate_limit] do
      nil ->
        fun.()

      limit ->
        deadline = System.monotonic_time(:millisecond) + (provider_opts[:max_wait] || 30_000)
        attempt(r.provider, limit, provider_opts[:max_retries] || 3, 0, deadline, fun)
    end
  end

  defp attempt(provider, limit, max_retries, n, deadline, fun) do
    require Logger
    :ok = AgentManager.Models.RateLimiter.acquire(provider, limit)

    case fun.() do
      {:error, {:http, status, body}} = error when status in [429, 503] and n < max_retries ->
        delay = retry_delay(body) || min(2_000 * Integer.pow(2, n), 60_000)

        cond do
          daily_quota?(body) ->
            Logger.warning("[models] #{provider} daily quota exhausted; not retrying")
            error

          System.monotonic_time(:millisecond) + delay > deadline ->
            Logger.warning(
              "[models] #{provider} returned #{status}; retry in #{delay}ms exceeds max_wait, giving up"
            )

            error

          true ->
            Logger.warning(
              "[models] #{provider} returned #{status}; retrying in #{delay}ms (#{n + 1}/#{max_retries})"
            )

            Process.sleep(delay)
            attempt(provider, limit, max_retries, n + 1, deadline, fun)
        end

      result ->
        result
    end
  end

  # Google reports which quota was hit, e.g. "GenerateRequestsPerDayPerProjectPerModel-FreeTier".
  defp daily_quota?(body) do
    body
    |> List.wrap()
    |> Enum.any?(fn
      %{"error" => %{"details" => details}} when is_list(details) ->
        Enum.any?(details, fn
          %{"violations" => violations} when is_list(violations) ->
            Enum.any?(violations, &(is_binary(&1["quotaId"]) and &1["quotaId"] =~ "PerDay"))

          _ ->
            false
        end)

      _ ->
        false
    end)
  end

  # Google's RetryInfo detail: "retryDelay": "59s" (possibly fractional).
  defp retry_delay(body) do
    body
    |> List.wrap()
    |> Enum.find_value(fn
      %{"error" => %{"details" => details}} when is_list(details) ->
        Enum.find_value(details, fn
          %{"retryDelay" => delay} when is_binary(delay) ->
            case Float.parse(delay) do
              {seconds, "s"} -> round(seconds * 1000)
              _ -> nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end)
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
    |> then(fn o ->
      # rate-limited providers are retried by `limited/3`, not blindly by the HTTP client
      if r.opts[:rate_limit],
        do: Keyword.update(o, :req_options, [retry: false], &Keyword.put(&1, :retry, false)),
        else: o
    end)
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

  # Providers configured with an `api_key` need one at call time (from the
  # environment or the bot's api_keys). Without it the provider would answer
  # with an opaque auth error; say which variable to set instead.
  defp check_key(%Resolved{} = r, call_opts, opts) do
    configured =
      Application.get_env(:agent_manager, __MODULE__, [])
      |> Keyword.get(:providers, [])
      |> Enum.find_value(fn {name, p} -> to_string(name) == r.provider && p[:api_key] end)

    if configured && call_opts[:api_key] in [nil, ""] do
      hint =
        case configured do
          {:system, var} -> "set #{var} (or the bot's api_keys.#{r.provider})"
          _ -> "set the #{r.provider} api_key"
        end

      error = {:error, {:missing_api_key, hint}}
      report(r, error, 0, call_opts, opts)
      error
    else
      :ok
    end
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
