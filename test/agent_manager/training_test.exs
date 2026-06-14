defmodule AgentManager.TrainingTest do
  use AgentManager.Case

  alias AgentManager.{Bots, Events, Knowledge, Training, VectorStore}
  alias AgentManager.Training.Coordinator

  @content %{
    "bot_name" => "Loja",
    "source_text" =>
      "Nosso horário de funcionamento é de segunda a sexta, das 9h às 18h, e aos sábados das 9h às 13h.\n\nAceitamos pagamento em cartão de crédito, débito, pix e boleto bancário em todas as compras do site.\n\nA entrega é feita em até cinco dias úteis para todo o Brasil. Mais em https://loja.example.com/entrega",
    "behavioral_rules" => "Você é um atendente da loja. [pt] [*en]"
  }

  test "training indexes segments, infers settings and reports progress" do
    bot = create_bot!()
    Events.subscribe({:bot, bot.id})

    {:ok, bot} = Training.request(bot, @content)
    assert bot.training_info.status == :ON_TRAINING

    assert_event("training.started")
    assert_event("training.progress")
    completed = assert_event("training.completed", 5_000)
    assert completed.payload.stats.new_segments == 3

    wait_until(fn -> Bots.get(bot.id).training_info.status == :FINISHED end)
    bot = Bots.get(bot.id)
    content = bot.model_config.content
    assert content.language.allowed_languages == ["Portuguese", "English"]
    assert content.language.default_language == "English"
    assert "https://loja.example.com/entrega" in content.source_urls

    assert {:ok, [top | _]} =
             Knowledge.search(bot, "Quais formas de pagamento vocês aceitam, pix?", 3)

    assert top.segment =~ "pagamento"
  end

  test "retraining only embeds new segments and drops stale ones" do
    bot = create_bot!() |> train!(@content)
    assert VectorStore.impl().count(bot.id) == 3

    Events.subscribe({:bot, bot.id})

    changed = %{
      @content
      | "source_text" =>
          @content["source_text"] <> "\n\nTrocas podem ser feitas em até trinta dias corridos."
    }

    changed =
      Map.put(
        changed,
        "source_text",
        String.replace(
          changed["source_text"],
          "cartão de crédito, débito, pix e boleto bancário",
          "boleto bancário, transferência e dinheiro na retirada"
        )
      )

    {:ok, _} = Training.request(bot, changed)

    stats = assert_event("training.completed", 5_000).payload.stats
    assert %{new_segments: 2, deleted_segments: 1, total_segments: 4} = stats
  end

  test "rules over the budget fail the job and mark the bot ERROR" do
    bot = create_bot!()
    Events.subscribe({:bot, bot.id})

    {:ok, _} =
      Training.request(bot, %{@content | "behavioral_rules" => String.duplicate("regra ", 3_000)})

    failed = assert_event("training.failed", 5_000)
    assert [message] = failed.payload.errors
    assert message =~ "Behavioral rules too long"
    wait_until(fn -> Bots.get(bot.id).training_info.status == :ERROR end)
  end

  test "an embedding provider failure fails the job without killing the coordinator" do
    bot = create_bot!(%{"model_config" => %{"embedding_model" => "nope:embed"}})
    Events.subscribe({:bot, bot.id})
    coordinator = Process.whereis(Coordinator)

    {:ok, _} = Training.request(bot, @content)
    assert assert_event("training.failed", 5_000).payload.errors |> hd() =~ "unknown_provider"
    assert Process.whereis(Coordinator) == coordinator
  end

  describe "recovery" do
    setup do
      # Make training slow enough to interrupt, via a config edit to the pipeline.
      slow = {fn ctx, _ -> Process.sleep(300) && {:ok, ctx} end, name: :slow}

      Application.put_env(:agent_manager, AgentManager.Pipelines.Training,
        edits: [{:insert_before, AgentManager.Pipelines.Training.Steps.Index, slow}]
      )

      on_exit(fn -> Application.delete_env(:agent_manager, AgentManager.Pipelines.Training) end)
    end

    test "a crashed coordinator is restarted and adopts the running job instead of duplicating it" do
      bot = create_bot!()
      Events.subscribe({:bot, bot.id})
      {:ok, _} = Training.request(bot, @content)
      assert_event("training.started")

      old = Process.whereis(Coordinator)
      Process.exit(old, :kill)
      wait_until(fn -> Process.whereis(Coordinator) not in [nil, old] end)

      assert Coordinator.status().running == [bot.id]
      assert_event("training.completed", 5_000)
      refute_receive {:event, %{type: "training.started"}}, 400
      wait_until(fn -> Coordinator.status().running == [] end)
    end

    test "requests interrupted by a restart are re-queued from the store" do
      bot = create_bot!()

      # What a node that died mid-queue leaves behind: ON_TRAINING, no job.
      {:ok, _} =
        Bots.set_training_info(bot, %{"status" => "ON_TRAINING", "data_json" => @content})

      Events.subscribe({:bot, bot.id})
      :ok = Supervisor.terminate_child(AgentManager.Training.Root, Coordinator)
      {:ok, _} = Supervisor.restart_child(AgentManager.Training.Root, Coordinator)

      assert_event("training.started")
      assert assert_event("training.completed", 5_000).payload.stats.new_segments == 3
      wait_until(fn -> Bots.get(bot.id).training_info.status == :FINISHED end)
      assert Bots.get(bot.id).model_config.content.bot_name == "Loja"
    end
  end

  test "requests for a bot that is already training are coalesced" do
    bot = create_bot!()
    Events.subscribe({:bot, bot.id})

    # Queue three requests while the coordinator is paused: the first starts
    # right away, the other two collapse into one run with the latest content.
    :sys.suspend(Coordinator)

    for n <- 1..3, do: {:ok, _} = Training.request(bot, %{@content | "bot_name" => "v#{n}"})
    :sys.resume(Coordinator)

    assert_event("training.started")
    assert_event("training.completed", 5_000)
    assert_event("training.started")
    assert_event("training.completed", 5_000)
    refute_receive {:event, %{type: "training.started"}}, 300
    wait_until(fn -> Bots.get(bot.id).model_config.content.bot_name == "v3" end)
  end
end
