# AI Agent Manager (Elixir)

An AI agent (chatbot) engine built with Elixir, Phoenix and OTP: many bots per deployment,
each trained on your own content, answering through an HTTP API. It is built around three ideas:

- **Event-driven:** everything that happens is an event on a PubSub bus, and
  persistence, usage accounting, training status, webhooks and live sockets are
  all independent subscribers.
- **Modular pipelines:** answering and training are declared as step lists. You
  can reorder, replace, time-box, retry or parallelise steps, in code or from config.
- **Swappable models:** every model is addressed as `"provider:model"`. Switching
  a bot from OpenAI to Claude or to a local Ollama model is a single `PATCH`.

## Quick start

```bash
mix deps.get

# No infrastructure at all: in-memory storage + fake models
STORE=memory MODELS=fake mix phx.server

# Real setup: Postgres with pgvector + a provider key
docker compose up -d db
export OPENAI_API_KEY=...        # and/or ANTHROPIC_API_KEY, OLLAMA_URL
mix ecto.setup
mix phx.server

mix test                         # no DB or network needed
```

Postgres needs the `vector` extension (the compose file uses `pgvector/pgvector`).
Connection settings come from `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT` in dev, and `DATABASE_URL` in prod.
PDF training sources need `pdftotext` (poppler-utils) on the PATH.

## Architecture

```
HTTP (Phoenix controllers)            WebSocket  bot:<id>  (live events)
      │                                      ▲
      ▼                                      │
Conversations ──► Conversations.Server ──► Pipelines.Answer ──► Models ──► OpenAI / Anthropic / Ollama / Bumblebee / Fake
  (one process per {bot, user})                 │                 │
      │                                         ▼                 ▼
      │                                  Knowledge / VectorStore  llm.completed
      ▼                                                           │
  Events (Phoenix.PubSub) ◄───────────────────────────────────────┘
      │
      ├─► MessageRecorder   (message.answered / message.recorded → Store)
      ├─► UsageRecorder     (llm.completed → llm_calls + bot token counter)
      ├─► TrainingRecorder  (training.completed / failed → bot.training_info)
      ├─► Training.Coordinator (training.requested → queued, supervised jobs)
      ├─► Webhooks          (any event → configured HTTP endpoints)
      └─► EventLogger
```

Supervision tree (see `AgentManager.Application`):

```
AgentManager.Supervisor (one_for_one)
├── Telemetry, Repo | Store.Memory, DNSCluster
├── Phoenix.PubSub                      the event bus
├── Task.Supervisor                     step timeouts, parallel steps, webhooks
├── Models.Supervisor                   local model servings (Nx.Serving)
├── Events.Supervisor                   one GenServer per handler
├── Conversations.Root (rest_for_one)   Registry + DynamicSupervisor of conversation servers
├── Training.Root (rest_for_one)        Task.Supervisor + Coordinator
└── Endpoint
```

What the BEAM gives us here:

- **One process per conversation.** Each user's messages are handled strictly in order,
  and different users are handled in parallel. The live history stays in memory, and the
  inactivity/NPS timers are plain `Process.send_after` calls, so no cron
  job has to scan the database.
- **Isolation.** A step with a `timeout:` runs in its own supervised task. A crashing
  training job is reported as `training.failed` and the coordinator keeps going. An
  exception in one event handler is logged and does not affect the others.
- **Concurrency.** Language detection and retrieval run in parallel for each answer.
  Training fetches sources and embeds batches concurrently. Local models run as
  `Nx.Serving`s that batch requests from the whole node.
- **Distribution.** PubSub events reach handlers on every node of a cluster (`DNSCluster`).

## Pipelines

A pipeline is a module that lists its steps:

```elixir
defmodule AgentManager.Pipelines.Answer do
  use AgentManager.Pipeline

  step Steps.RunCommands
  step Steps.CheckDisabled
  step Steps.PrepareHistory
  step Steps.StartMessage
  parallel [Steps.DetectLanguage, {Steps.RetrieveContext, k: 100, min_segments: 5}], name: :enrich
  step Steps.InactivityFollowUp, when: :asked_if_more_help
  step Steps.AttendanceConfirmation, when: :offered_attendance
  step Steps.BuildPrompt
  step Steps.Generate, retry: 1, timeout: 90_000, on_error: {:recover, &Steps.Generate.recover/2}
  step Steps.ResolveAttachments, on_error: :continue
  step Steps.ShapeAnswer
end
```

A step is a module with `call(ctx, opts)`. It returns `{:ok, ctx}`, `{:halt, ctx}`
or `{:error, reason, ctx}`. It reads the input from `ctx.input`, passes data to later
steps through `ctx.assigns`, and sets `ctx.result`. Model calls made through
`Pipelines.Answer.Helpers` add to `ctx.usage` automatically.

| Option | Effect |
|---|---|
| `when:` | assigns key or `fn ctx -> bool end`; the step is skipped when it's false |
| `retry:` | extra attempts on error or crash, with backoff |
| `timeout:` | runs the step in a supervised task and kills it on expiry |
| `on_error:` | `:halt` (default), `:continue`, or `{:recover, fn ctx, reason -> ctx end}` |
| `parallel [...]` | branches run concurrently; their assigns, usage and errors are merged |
| `step :name, fn ctx, opts -> ... end` | an inline step |

Changing a pipeline without editing it:

```elixir
# at runtime (e.g. per request)
steps =
  Answer.steps()
  |> Pipeline.replace(Steps.Generate, {MyStreamingGenerate, timeout: 60_000})
  |> Pipeline.insert_after(Steps.BuildPrompt, RedactPII)
Answer.run(input, bot: bot, steps: steps)

# or for the whole deployment
config :agent_manager, AgentManager.Pipelines.Answer,
  edits: [{:remove, Steps.ResolveAttachments}, {:insert_before, Steps.ShapeAnswer, AuditLog}]
```

`until:` stops after a given step. That's how `generate_prompt` shows the exact
prompt without calling the model. Every step emits `[:agent_manager, :pipeline, :step, ...]`
telemetry and a `pipeline.step.completed` event, and `ctx.trace` records the run.
`GET /pipelines` lists the steps currently in effect.

Other extension points follow the same pattern:

| What | Config key |
|---|---|
| chat commands (`+limpar historico`) | `AgentManager.Commands, commands: [...]` |
| file parsers by extension | `AgentManager.Sources, parsers: %{"pdf" => MyOCR}` |
| language-detector chain | `AgentManager.NLP.Language, detectors: [...]` |
| sentiment classifier | `AgentManager.NLP.Sentiment, impl: ...` |
| token counter | `AgentManager.NLP.Tokenizer, impl: ...` |
| event handlers | `AgentManager.Events.Supervisor, handlers: [...]` |
| storage | `:store` / `:vector_store` (Ecto/pgvector or in-memory) |

## Training recovery

`Training.request/3` writes `ON_TRAINING` to the store, together with the content and the
`overload` flag, before it publishes `training.requested`. So the durable state of the queue
is the set of bots marked `ON_TRAINING`. Every time the Coordinator starts, it rebuilds
its in-memory queue from that:

| What happened | Recovery |
|---|---|
| A job crashes | the Coordinator (monitoring the job) publishes `training.failed`, the bot goes to `ERROR`, and the Coordinator carries on |
| The Coordinator crashes | the supervisor restarts it. Running jobs aren't linked to it, so they keep going; each one registered itself in `Training.Registry`, and the new Coordinator adopts it rather than starting a duplicate. Bots that were waiting are re-queued from the store |
| The node dies or restarts | at boot, every bot still `ON_TRAINING` is re-queued and runs again |

Re-running an interrupted job is safe. Training only embeds segments that aren't indexed
yet, and it swaps the index in one transaction.

**Why not Redis?** It would add a second piece of infrastructure to hold state that Postgres
already has. If you outgrow this setup (several nodes, retries with backoff, scheduled jobs,
a job dashboard), the natural next step is [Oban](https://hexdocs.pm/oban). Oban stores jobs
in the same Postgres database, keeps them unique per bot, and limits concurrency per queue.
The Coordinator would become a thin Oban worker that calls `Coordinator.run/1`.

## API keys and secrets

Keys are resolved at call time, in this order:

1. **Per bot:** `model_config.api_keys`, keyed by provider name. The key for a bot's
   provider overrides the global key for that bot. Set it with
   `PATCH /bot/:id/models {"api_keys": {"anthropic": "sk-ant-..."}}`, or with the legacy
   `openai_key` field / `PATCH /bot/:id/openai_key/:value`, which fills `api_keys.openai`.
   API responses only ever return a hint like `sk-an...wxyz`.
2. **Global, from the environment:** `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
   `OLLAMA_URL`. These are wired in `config/config.exs` as `{:system, "VAR"}`. They're read
   when each request is made, so they work in releases and changing the variable needs no rebuild.
3. **Local development:** copy `.env.example` to `.env` (gitignored). `config/config.exs`
   loads it in dev only (tests stay independent of it); variables already set in the
   shell take precedence.

Default models can also be set per deployment with `DEFAULT_CHAT_MODEL`,
`DEFAULT_UTILITY_MODEL` and `DEFAULT_EMBEDDING_MODEL`. For example, a Gemini-only setup:
`DEFAULT_CHAT_MODEL=gemini:gemini-3.8-flash DEFAULT_EMBEDDING_MODEL=gemini:gemini-embedding-001`.

A new provider or gateway only needs a config entry, e.g.
`groq: [adapter: Adapters.OpenAI, base_url: "...", api_key: {:system, "GROQ_API_KEY"}]`.
After that, `"groq:<model>"` works in any bot. Per-bot keys are stored in the
`bots.model_config` JSON column in plain text, like the rest of the bot's configuration.
If that matters, encrypt that field (e.g. with Cloak).

## Swapping providers: what is seamless and what isn't

The pipeline never sees a provider's wire format. Each adapter translates its provider's
request and response into one internal shape: messages with roles, plus
`%{content, usage}`. Conversation history is stored as plain text, so a conversation can
move from Gemini to OpenAI to Anthropic between two messages. `provider_swap_test.exs`
does exactly that against each provider's real wire format.

| | Seamless? |
|---|---|
| Chat model (`llm_model`, `utility_model`) | **Yes.** Takes effect on the next message, and history carries over. |
| JSON answers | **Yes.** OpenAI and Gemini use JSON mode, Ollama `format: json`, and Anthropic an instruction. All are parsed leniently, so a model that ignores the format still produces an answer. |
| Usage / cost accounting | **Yes.** It's recorded per call with the provider-qualified model name. |
| Missing or invalid key | **Graceful.** The call fails, and the bot answers with the "technical problems" human handoff instead of crashing. Fixing the key or switching the model resumes normal answers. |
| Embedding model (`embedding_model`) | **No, it needs a retrain.** Vectors from different models aren't comparable, so segments are tagged with their model and a changed model finds nothing until you retrain. Anthropic has no embeddings API, so Claude-answering bots still need an OpenAI, Gemini, Ollama or local embedding model. |
| Prompt size | Budgets are per provider/model (`budgets`), so the amount of retrieved context adapts automatically. |

## Models

```elixir
config :agent_manager, AgentManager.Models,
  providers: [
    openai:    [adapter: Adapters.OpenAI, api_key: {:system, "OPENAI_API_KEY"}],
    groq:      [adapter: Adapters.OpenAI, base_url: "https://api.groq.com/openai/v1", api_key: ...],
    anthropic: [adapter: Adapters.Anthropic, api_key: {:system, "ANTHROPIC_API_KEY"}],
    ollama:    [adapter: Adapters.Ollama, base_url: "http://gpu-box:11434"]
  ],
  aliases: %{"gpt-3.5-turbo" => "openai:gpt-4o-mini"},   # legacy names still resolve
  defaults: [chat: "openai:gpt-4o-mini", utility: nil, embedding: "openai:text-embedding-3-small"],
  budgets: %{"openai" => 12_000}                           # prompt tokens per model/provider
```

Each bot has a `model_config` with these fields:

- `llm_model`: the model that answers.
- `utility_model`: used for classification, paraphrasing and attachment picking.
  It falls back to `llm_model`; a cheaper model saves cost here.
- `embedding_model`: used for retrieval. After changing it, retrain the bot.
  Segments are tagged with the model that embedded them.
- `api_keys`: per-provider keys that override the global ones.

```bash
curl -X PATCH localhost:4000/bot/<id>/models -H 'content-type: application/json' \
  -d '{"llm_model": "anthropic:claude-opus-5", "utility_model": "ollama:llama3.1",
       "api_keys": {"anthropic": "sk-ant-..."}}'
```

To add a provider, implement `AgentManager.Models.ChatModel` and/or `EmbeddingModel`
(one function each) and list it under `providers`. Local embeddings with
Bumblebee: build with `LOCAL_MODELS=1`, then add
`providers: [local: [adapter: Adapters.Bumblebee]]` and
`servings: [{"local:intfloat/multilingual-e5-large", :embedding}]`.

## Tool calling and MCP

Bots can call tools while answering. There are two kinds:

- **Local tools** are Elixir modules implementing `AgentManager.Tools.Tool`. Two ship
  with the app: `current_time`, and `search_knowledge`, which lets the model run
  extra searches over the bot's own knowledge base.
- **MCP tools** come from any [Model Context Protocol](https://modelcontextprotocol.io)
  server, over stdio (a local process) or Streamable HTTP (a remote server).

```elixir
config :agent_manager, AgentManager.MCP,
  servers: [
    %{name: "filesystem", transport: :stdio, command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/docs"]},
    %{name: "crm", transport: :http, url: "https://crm.example.com/mcp",
      headers: %{"authorization" => {:system, "CRM_MCP_TOKEN"}}}
  ]
```

MCP servers can also come from `MCP_SERVERS`, a JSON array with the same fields, or be
started in code with `AgentManager.MCP.start_server/1`. Each server is one supervised
`MCP.Client` process:

- If a server can't be reached, or it crashes, the client marks it `:error` and reconnects
  with backoff; the rest of the app is unaffected.
- The client caches the server's tool list and refreshes it when the server sends
  `notifications/tools/list_changed`.
- Several calls to the same server can be in flight at once.

Tools are **off by default**. A bot opts in with ids or globs:

```bash
curl -X PATCH localhost:4000/bot/<id>/tools -H 'content-type: application/json' \
  -d '{"tools": ["local:current_time", "mcp:crm/*"]}'
```

`GET /tools` lists every available tool with its id. `GET /mcp/servers` shows each
server's status, tool count and last error.

How a tool round works inside the `Generate` step:

1. The model is called with the bot's tools.
2. If it asks for any tools, they run **concurrently**, each in a supervised task with a
   timeout (`config :agent_manager, AgentManager.Tools, timeout: 30_000`).
3. Results, including errors, go back to the model and the loop repeats.
4. After 5 rounds (`step Steps.Generate, max_tool_rounds: n` to change it) the model is
   told to answer with what it has.

Each call publishes `tool.called` and `tool.completed` events, token usage keeps
accumulating, and the answer's metadata lists `tools_used`. Tool calling works on every
adapter (OpenAI and Gemini, Anthropic, Ollama); each translates the provider's native
tool format. Only the question and the final answer go into conversation history, so
switching providers mid-conversation still works when tools are in use.

MCP support covers **tools**. Resources, prompts, sampling and elicitation are not
implemented, and remote servers authenticate with static headers only (no OAuth flow yet).
Stdio servers run as OS processes on the app's host with its permissions; enable only
servers you trust. Keep in mind that end users' messages can steer which tools a model calls.

## Caps and abuse protection

Spending is bounded in layers, so no single bug or open route can run up a bill:

1. **Model budget (the hard cap).** Every chat-model call goes through
   `AgentManager.Budget`, whatever started it: the HTTP API, tool rounds, an app built on
   top. Calls are reserved atomically before the request; over budget, the call is refused
   without reaching the provider. Set it with `MODEL_CALLS_DAILY` / `MODEL_TOKENS_DAILY`
   (per UTC day; unset is unlimited). Calls made with `budget: :qa` (evaluations) have a
   budget of their own (`QA_CALLS_DAILY` / `QA_TOKENS_DAILY`), so they never starve live
   answers. The limits can also come from your own module (e.g. runtime settings), see
   [Building on the engine](#building-on-the-engine).
2. **Per-IP rate limits on HTTP:** 120 requests/min on the API by default. Override per
   bucket with `config :agent_manager, AgentManagerWeb.Plugs.RateLimit, api: {limit, window_ms}`.
   Behind a reverse proxy, set `TRUSTED_PROXIES`; `X-Forwarded-For` is only believed from
   those addresses.
3. **Token brute force:** 10 failed attempts from one IP lock it out for 15 minutes, on
   both the HTTP API and `/socket`.
4. **Inputs:** uploads are size-capped, and zip-based files (DOCX, XLSX) are checked
   against a 50 MB unpacked limit before they are extracted.

For a cap that holds even if this app misbehaves, also set a quota at your model
provider; it's the only limit enforced outside the app.

Rate-limit counters are kept in memory on one node, which is fine for a single server. A
cluster needs a shared store for them.

## Building on the engine

The engine is a regular OTP application, so a product can depend on it and add its own
channels, flows and admin routes without forking it. Every hook is configuration, set
from the product's own `config/*.exs`:

| Hook | Config |
|---|---|
| extra supervisors, started before the endpoint | `config :agent_manager, children: [MyApp.Supervisor]` |
| your router first; forward the rest with `forward "/", AgentManagerWeb.Router` | `config :agent_manager, router: MyAppWeb.Router` |
| more event handlers, keeping the defaults | `AgentManager.Events.Supervisor, extra_handlers: [...]` |
| prompt wording (`AgentManager.Prompts` behaviour) | `AgentManager.Prompts, impl: MyApp.Prompts` |
| budget limits from your own source (`AgentManager.Budget` behaviour) | `AgentManager.Budget, limits: MyApp.Settings` |
| groups of local tools under their own prefix (`demo:*`) | `AgentManager.Tools, groups: %{"demo" => MyApp.DemoTools}` |
| answer / training pipeline edits | `AgentManager.Pipelines.Answer, edits: [...]` |

```elixir
# mix.exs of the product
{:agent_manager, github: "pgscasado/ai-agent-manager-core"}
```

Migrations ship with the engine (`priv/repo/migrations`), so `mix ecto.migrate` in the
product runs them once it sets `config :my_app, ecto_repos: [AgentManager.Repo]`.

## Events

The full catalogue is in `AgentManager.Events`. The main ones are `message.received`,
`message.answered`, `message.recorded`, `conversation.cleared`, `conversation.inactive`,
`conversation.nps_due`, `llm.completed`, `llm.failed`, `tool.called`, `tool.completed`,
`pipeline.step.completed`,
`training.requested`, `training.started`, `training.progress`, `training.completed`,
`training.failed`, `bot.created/updated/deleted` and `budget.exhausted`.

To add behaviour, write a handler and register it:

```elixir
defmodule MyApp.CRMSync do
  use AgentManager.Events.Handler, subscribe: ["conversation.nps_due"]
  def handle_event(event, state), do: {send_survey(event.bot_id, event.payload.user_id), state} |> then(fn {_, s} -> {:ok, s} end)
end
```

Clients can follow a bot live through the Phoenix channel `bot:<id>` on `/socket`,
or receive events as webhooks via `AgentManager.Handlers.Webhooks`.

To watch everything on the server's console, start it with `LIVE_TRACE=true`:

```
         tool     current_time {}
         tool     ✓ current_time 1ms → {"now":"2026-10-01T09:00:00-03:00"}
         model    gemini:... · 3463 in / 55 out · 1.1s
         pipeline support-bot commands › history › language › retrieval › prompt › generate 2.1s › shape
         answer   We're open until 6pm today. · 3463 in / 55 out
```

The trace covers:
- **Model calls:** tokens and latency.
- **Tool calls:** arguments and a preview of each result.
- **Pipeline:** each run's steps, with the slow ones timed.
- **Training.**

## HTTP API

Every route is served both at `/` and under `/1.0`:

| Method | Path | Notes |
|---|---|---|
| POST | `/bot` | also accepts the 1.0 payload shape (`openai_config`/`temp_content`/`openai_key`); starts training |
| GET | `/bot?cursor=&size=` | cursor pagination |
| POST | `/bot/training` | `{ids: [...]}` → training status per bot |
| GET/PUT/DELETE | `/bot/:id` | `:id` is either the id or the `identifier` |
| PUT | `/bot/:id/update_prompt` | retrain (`?overload=true` skips the rules-size check) |
| POST | `/bot/:id/topK` | top 5 segments |
| POST | `/message/:id/get_answer` | main chat endpoint (flags as `"true"`/`"false"` strings) |
| POST | `/bot/:id/get_answer` | legacy variant with `usage` |
| POST | `/message/:id/bot_message`, `/message/:id/user_message` | record messages sent outside the bot |
| PATCH | `/bot/:id/{temperature,ai,openai_key,allow_attendance_on_greeting,allow_direct_attendance,user_history_time,access_control,disabled,gpt_language_detector,start_message}/:value` | `value` is coerced (`yes`/`off`/`0`..., `:unset` clears `start_message`) |
| PATCH | `/bot/:id/job_timings` | `{nps, inactive}` minutes → timer events |
| PATCH | `/bot/:id/models` | swap models / keys |
| GET | `/bot/:id/prompt_token_limit`, POST `/bot/:id/paraphrase` | |
| GET | `/debug/language[/:bot_id]`, `/debug/sentiment`, POST `/debug/tokens`, GET `/debug/:id/generate_prompt` | `generate_prompt` also returns the pipeline trace |
| PATCH | `/bot/:id/tools` | `{tools: [ids or globs]}` |
| GET | `/models`, `/pipelines`, `/tools`, `/mcp/servers` | introspection |

When `API_TOKEN` is set, every route above requires
`Authorization: Bearer <token>`, and `/socket` requires it as the `token` param.

### Design notes

- **Storage:** Postgres + pgvector. The `vector`
  column has no fixed dimension, so bots can use different embedding models. For large
  indexes, add a partial HNSW index per model, for example:
  `CREATE INDEX ON segments USING hnsw ((embedding::vector(1536)) vector_cosine_ops) WHERE embedding_model = 'openai:text-embedding-3-small';`.
- **No required local models:** embeddings come from the configured provider (or Ollama /
  Bumblebee when you want them local); language detection uses greeting lists + stopword
  scoring with an optional LLM stage; sentiment uses the utility model.
- **Token counting** is an estimate (about 3.5 characters per token) behind a swappable
  behaviour, so a real tokenizer can be plugged in.
- **Persistence:** the answer is returned before persistence finishes. The conversation
  process holds the history, so the next message never races the database write.
- **Segmentation** is by paragraph (short paragraphs merge into the previous one); sheet
  rows become one segment each.

### Known gaps

- **Single-node training queue:** the Coordinator is a single process per node. In a
  cluster, each node would recover and run the same `ON_TRAINING` bots. Before running
  multiple nodes, make it a cluster singleton or move the queue to Oban (see Training recovery).
- **One shared token:** `API_TOKEN` protects the API and the socket as a whole. There are
  no per-client tokens or scopes yet.
- **Untested paths:** the Bumblebee adapter and the Postgres/pgvector store are not covered
  by the test suite, which runs on the in-memory store and a fake provider.

## License

[AGPL-3.0](LICENSE). You can run, modify and build on it; if you offer a modified
version as a network service, its source must be available to its users.
