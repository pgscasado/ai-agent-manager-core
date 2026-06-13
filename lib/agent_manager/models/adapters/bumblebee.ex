if Code.ensure_loaded?(Bumblebee) do
  defmodule AgentManager.Models.Adapters.Bumblebee do
    @moduledoc """
    On-BEAM embeddings with Bumblebee + `Nx.Serving` (opt-in: `LOCAL_MODELS=1`).

    The model is loaded once into an `Nx.Serving` that is started
    under `AgentManager.Models.Supervisor` and batches concurrent requests from
    every process in the node.

        config :agent_manager, AgentManager.Models,
          providers: [local: [adapter: AgentManager.Models.Adapters.Bumblebee]],
          servings: [{"local:intfloat/multilingual-e5-large", :embedding}]

    Then use `"local:intfloat/multilingual-e5-large"` as a bot's
    `embedding_model`.
    """

    @behaviour AgentManager.Models.EmbeddingModel

    @doc "Child spec for the serving of `repo` (a Hugging Face repo id)."
    def child_spec({repo, :embedding}) do
      {:ok, model} = Bumblebee.load_model({:hf, repo})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, repo})

      serving =
        Bumblebee.Text.text_embedding(model, tokenizer,
          output_pool: :mean_pooling,
          output_attribute: :hidden_state,
          embedding_processor: :l2_norm,
          compile: [batch_size: 16, sequence_length: 512],
          defn_options: [compiler: EXLA]
        )

      %{
        id: {__MODULE__, repo},
        start:
          {Nx.Serving, :start_link,
           [[serving: serving, name: serving_name(repo), batch_timeout: 50]]}
      }
    end

    def serving_name(repo), do: {:via, Registry, {AgentManager.Models.Registry, repo}}

    @impl true
    def embed(texts, opts) do
      vectors =
        serving_name(opts[:model])
        |> Nx.Serving.batched_run(texts)
        |> Enum.map(&Nx.to_flat_list(&1.embedding))

      {:ok, vectors}
    rescue
      e -> {:error, e}
    end
  end
end
