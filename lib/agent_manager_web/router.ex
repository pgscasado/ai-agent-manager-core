defmodule AgentManagerWeb.Router do
  use AgentManagerWeb, :router

  # Per-IP limits (requests per minute) run before anything else, so floods
  # are cut before they reach auth or the database.
  pipeline :api do
    plug :accepts, ["json"]
    plug AgentManagerWeb.Plugs.RateLimit, bucket: :api, limit: 120
    plug AgentManagerWeb.Plugs.ApiAuth, required: false
  end

  pipeline :admin do
    plug :accepts, ["json"]
    plug AgentManagerWeb.Plugs.RateLimit, bucket: :admin, limit: 30
    plug AgentManagerWeb.Plugs.ApiAuth, required: true
  end

  # Meta calls this without our token; POSTs are verified by signature instead.
  # Every delivery comes from Meta's servers, so the IP limit is generous; the
  # per-number limit (messages_per_minute) applies inside the controller.
  pipeline :webhook do
    plug :accepts, ["json"]
    plug AgentManagerWeb.Plugs.RateLimit, bucket: :webhook, limit: 600
  end

  scope "/whatsapp", AgentManagerWeb do
    pipe_through :webhook
    get "/webhook", WhatsAppController, :verify
    post "/webhook", WhatsAppController, :receive
  end

  # Channels: each turns its webhook into a showcase message (see AgentManager.Channels).
  scope "/channels", AgentManagerWeb do
    scope "/whatsapp" do
      pipe_through :webhook
      get "/webhook", WhatsAppController, :verify
      post "/webhook", WhatsAppController, :receive
    end

    scope "/http" do
      pipe_through :api
      post "/messages", HttpChannelController, :create
      get "/messages", HttpChannelController, :index
    end
  end

  scope "/admin/showcase", AgentManagerWeb do
    pipe_through :admin
    get "/settings", ShowcaseAdminController, :show_settings
    put "/settings", ShowcaseAdminController, :update_settings
    delete "/settings", ShowcaseAdminController, :reset_settings
    get "/usage", ShowcaseAdminController, :usage
    get "/messages", ShowcaseAdminController, :messages
    post "/seed", ShowcaseAdminController, :seed
  end

  # The API is served both at the root and under /1.0.
  for prefix <- ["/", "/1.0"] do
    scope prefix, AgentManagerWeb, as: false do
      pipe_through :api

      scope "/bot" do
        post "/", BotController, :create
        get "/", BotController, :index
        post "/training", BotController, :training_status
        get "/:id", BotController, :show
        put "/:id", BotController, :update
        delete "/:id", BotController, :delete
        post "/:id/topK", BotController, :top_k
        put "/:id/update_prompt", BotController, :update_prompt
        post "/:id/get_answer", MessageController, :legacy_answer
        get "/:id/generate_prompt", DebugController, :generate_prompt
        get "/:id/prompt_token_limit", BotController, :prompt_token_limit
        post "/:id/paraphrase", BotController, :paraphrase
        patch "/:id/models", BotController, :update_models
        patch "/:id/tools", BotController, :update_tools
        patch "/:id/job_timings", BotController, :job_timings

        patch "/:id/temperature/:value", BotController, :patch_model_field,
          private: %{field: :temperature}

        patch "/:id/ai/:value", BotController, :patch_model_field, private: %{field: :llm_model}

        patch "/:id/openai_key/:value", BotController, :patch_model_field,
          private: %{field: {:api_key, "openai"}}

        patch "/:id/allow_attendance_on_greeting/:value", BotController, :patch_field,
          private: %{field: :attendance_on_greeting}

        patch "/:id/allow_direct_attendance/:value", BotController, :patch_field,
          private: %{field: :direct_attendance}

        patch "/:id/user_history_time/:value", BotController, :patch_field,
          private: %{field: :user_history_time}

        patch "/:id/access_control/:value", BotController, :patch_field,
          private: %{field: :access_control}

        patch "/:id/disabled/:value", BotController, :patch_field, private: %{field: :disabled}

        patch "/:id/gpt_language_detector/:value", BotController, :patch_field,
          private: %{field: :gpt_language_detector}

        patch "/:id/start_message/:value", BotController, :patch_field,
          private: %{field: :start_message}
      end

      scope "/message" do
        post "/:id/get_answer", MessageController, :answer
        post "/:id/bot_message", MessageController, :bot_message
        post "/:id/user_message", MessageController, :user_message
      end

      scope "/debug" do
        get "/language", DebugController, :language
        get "/language/:bot_id", DebugController, :language
        get "/sentiment", DebugController, :sentiment
        post "/tokens", DebugController, :tokens
        get "/:id/generate_prompt", DebugController, :generate_prompt
      end

      get "/models", SystemController, :models
      get "/pipelines", SystemController, :pipelines
      get "/tools", SystemController, :tools
      get "/mcp/servers", SystemController, :mcp_servers
    end
  end
end
