defmodule Giulia.Intelligence.EmbeddingServing do
  @moduledoc """
  Thin wrapper around Nx.Serving for sentence embeddings.

  Loads sentence-transformers/all-MiniLM-L6-v2 (80MB, 384D output).
  Returns :ignore on failure so the daemon starts normally without
  semantic search capability.
  """

  require Logger

  @model_repo "sentence-transformers/all-MiniLM-L6-v2"

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts) do
    Logger.info("EmbeddingServing: Loading #{@model_repo}...")

    with {:ok, model_info} <- Bumblebee.load_model({:hf, @model_repo}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, @model_repo}) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          output_pool: nil,
          embedding_processor: :l2_norm,
          compile: [batch_size: 32, sequence_length: 128],
          defn_options: [compiler: EXLA]
        )

      Logger.info("EmbeddingServing: Model loaded successfully")

      try do
        Nx.Serving.start_link(serving: serving, name: Giulia.EmbeddingServing, batch_timeout: 50)
      rescue
        e ->
          Logger.warning("EmbeddingServing: Serving failed to start: #{Exception.message(e)}. Semantic search disabled.")
          :ignore
      catch
        :exit, reason ->
          Logger.warning("EmbeddingServing: Serving exited: #{inspect(reason)}. Semantic search disabled.")
          :ignore
      end
    else
      error ->
        Logger.warning("EmbeddingServing: Failed to load model: #{inspect(error)}. Semantic search disabled.")
        :ignore
    end
  rescue
    e ->
      Logger.warning("EmbeddingServing: #{Exception.message(e)}. Semantic search disabled.")
      :ignore
  end

  @doc """
  Check if the embedding serving is available.
  """
  @spec available?() :: boolean()
  def available? do
    case Process.whereis(Giulia.EmbeddingServing) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Returns the model name used for embeddings.
  """
  @spec model_name() :: String.t()
  def model_name, do: "all-MiniLM-L6-v2"
end
