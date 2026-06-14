defmodule AgentManagerWeb.Router do
  use AgentManagerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
    end
  end
end
