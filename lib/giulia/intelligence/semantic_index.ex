defmodule Giulia.Intelligence.SemanticIndex do
  @moduledoc """
  Hierarchical Semantic Search — Dual-Key Embeddings.

  Two vector types work together to find code by concept, not keyword:
  - **Architectural Vectors** (module-level): moduledoc + public function names
  - **Surgical Vectors** (function-level): function name + @doc + @spec

  Two-Stage Contextual Retrieval Pipeline:
  1. Broad Scan: cosine similarity against module vectors → top 3 modules
  2. Deep Scan: cosine similarity against function vectors in those modules → ranked results
  """

  use GenServer

  require Logger

  alias Giulia.Context.Store
  alias Giulia.Intelligence.EmbeddingServing

  @embedding_dims 384

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Trigger async embedding of all modules and functions in a project.
  No-op if EmbeddingServing is not available.
  """
  def embed_project(project_path) do
    GenServer.cast(__MODULE__, {:embed_project, project_path})
  end

  @doc """
  Two-stage semantic search: modules first, then functions within top modules.
  """
  def search(project_path, concept, top_k \\ 5) do
    GenServer.call(__MODULE__, {:search, project_path, concept, top_k}, 30_000)
  end

  @doc """
  Check if semantic search is available.
  """
  def available? do
    EmbeddingServing.available?()
  end

  @doc """
  Get embedding status for a project.
  """
  def status(project_path) do
    GenServer.call(__MODULE__, {:status, project_path})
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{embedding_in_progress: MapSet.new()}}
  end

  @impl true
  def handle_cast({:embed_project, project_path}, state) do
    if EmbeddingServing.available?() and not MapSet.member?(state.embedding_in_progress, project_path) do
      new_state = %{state | embedding_in_progress: MapSet.put(state.embedding_in_progress, project_path)}

      Task.start(fn ->
        do_embed_project(project_path)
        GenServer.cast(__MODULE__, {:embed_complete, project_path})
      end)

      {:noreply, new_state}
    else
      if not EmbeddingServing.available?() do
        Logger.debug("SemanticIndex: Skipping embed — EmbeddingServing not available")
      end

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:embed_complete, project_path}, state) do
    {:noreply, %{state | embedding_in_progress: MapSet.delete(state.embedding_in_progress, project_path)}}
  end

  @impl true
  def handle_call({:search, project_path, concept, top_k}, _from, state) do
    result = do_search(project_path, concept, top_k)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:status, project_path}, _from, state) do
    mod_count =
      case Store.get_embeddings(project_path, :module) do
        {:ok, entries} -> length(entries)
        :error -> 0
      end

    func_count =
      case Store.get_embeddings(project_path, :function) do
        {:ok, entries} -> length(entries)
        :error -> 0
      end

    result = %{
      available: EmbeddingServing.available?(),
      module_vectors: mod_count,
      function_vectors: func_count,
      model: EmbeddingServing.model_name(),
      embedding_in_progress: MapSet.member?(state.embedding_in_progress, project_path)
    }

    {:reply, result, state}
  end

  # ============================================================================
  # Embedding Pipeline
  # ============================================================================

  defp do_embed_project(project_path) do
    Logger.info("SemanticIndex: Starting dual-key embedding for #{project_path}")

    all_asts = Store.all_asts(project_path)

    # Type A: Architectural Vectors (one per module)
    module_entries = build_module_entries(all_asts, project_path)
    module_vectors = embed_batch(Enum.map(module_entries, & &1.text))

    module_entries =
      Enum.zip(module_entries, module_vectors)
      |> Enum.map(fn {entry, vector} ->
        %{id: entry.id, vector: vector, metadata: entry.metadata}
      end)

    Store.put_embeddings(project_path, :module, module_entries)

    # Type B: Surgical Vectors (one per public function)
    function_entries = build_function_entries(all_asts, project_path)
    function_vectors = embed_batch(Enum.map(function_entries, & &1.text))

    function_entries =
      Enum.zip(function_entries, function_vectors)
      |> Enum.map(fn {entry, vector} ->
        %{id: entry.id, vector: vector, metadata: entry.metadata}
      end)

    Store.put_embeddings(project_path, :function, function_entries)

    Logger.info(
      "SemanticIndex: Embedded #{length(module_entries)} modules (Architectural) + " <>
        "#{length(function_entries)} functions (Surgical) for #{project_path}"
    )
  end

  defp build_module_entries(all_asts, project_path) do
    all_asts
    |> Enum.flat_map(fn {path, ast_data} ->
      modules = ast_data[:modules] || []
      functions = ast_data[:functions] || []

      Enum.map(modules, fn mod ->
        # Get moduledoc
        moduledoc =
          case Store.get_moduledoc(project_path, mod.name) do
            {:ok, doc} -> doc
            :not_found -> ""
          end

        # Get public function names
        public_funcs =
          functions
          |> Enum.filter(&(&1.type == :def))
          |> Enum.map_join(", ", &"#{&1.name}/#{&1.arity}")

        text =
          ["Module: #{mod.name}"]
          |> maybe_append(moduledoc, moduledoc != "")
          |> maybe_append("Functions: #{public_funcs}", public_funcs != "")
          |> Enum.join("\n")

        %{
          id: mod.name,
          text: text,
          metadata: %{file: path, line: mod.line, moduledoc: moduledoc}
        }
      end)
    end)
  end

  defp build_function_entries(all_asts, project_path) do
    all_asts
    |> Enum.flat_map(fn {path, ast_data} ->
      modules = ast_data[:modules] || []
      functions = ast_data[:functions] || []

      module_name =
        case modules do
          [first | _] -> first.name
          _ -> "Unknown"
        end

      # Only embed public functions
      functions
      |> Enum.filter(&(&1.type == :def))
      |> Enum.map(fn func ->
        func_id = "#{module_name}.#{func.name}/#{func.arity}"

        # Get @doc
        doc_text =
          case Store.get_function_doc(project_path, module_name, func.name, func.arity) do
            %{doc: doc} when is_binary(doc) -> doc
            _ -> nil
          end

        # Get @spec
        spec_text =
          case Store.get_spec(project_path, module_name, func.name, func.arity) do
            %{spec: spec} when is_binary(spec) and spec != "" -> spec
            _ -> nil
          end

        text =
          ["Function: #{func_id}"]
          |> maybe_append("@doc #{doc_text}", doc_text != nil)
          |> maybe_append("@spec #{spec_text}", spec_text != nil)
          |> Enum.join("\n")

        %{
          id: func_id,
          text: text,
          metadata: %{
            module: module_name,
            function: to_string(func.name),
            arity: func.arity,
            file: path,
            line: func.line
          }
        }
      end)
    end)
  end

  defp maybe_append(list, _text, false), do: list
  defp maybe_append(list, text, true), do: list ++ [text]

  # ============================================================================
  # Batch Embedding
  # ============================================================================

  defp embed_batch([]), do: []

  defp embed_batch(texts) do
    texts
    |> Enum.chunk_every(32)
    |> Enum.flat_map(fn batch ->
      results = Nx.Serving.batched_run(Giulia.EmbeddingServing, batch)

      Enum.map(results, fn result ->
        result.embedding |> Nx.to_binary()
      end)
    end)
  end

  # ============================================================================
  # Two-Stage Search Pipeline
  # ============================================================================

  defp do_search(project_path, concept, top_k) do
    unless EmbeddingServing.available?() do
      {:error, "Semantic search unavailable. EmbeddingServing not loaded."}
    else
      case Store.get_embeddings(project_path, :module) do
        :error ->
          {:error, "No embeddings for this project. Run /api/index/scan first."}

        {:ok, module_entries} ->
          # Embed the query
          [query_result] = Nx.Serving.batched_run(Giulia.EmbeddingServing, [concept])
          query_vec = query_result.embedding

          # Stage 1: Broad Scan — find top 3 modules
          top_modules = rank_entries(module_entries, query_vec, 3)

          # Stage 2: Deep Scan — find functions in those top modules
          top_module_ids = Enum.map(top_modules, & &1.id) |> MapSet.new()

          function_results =
            case Store.get_embeddings(project_path, :function) do
              {:ok, func_entries} ->
                # Filter to functions in top modules
                relevant_funcs =
                  Enum.filter(func_entries, fn entry ->
                    MapSet.member?(top_module_ids, entry.metadata.module)
                  end)

                rank_entries(relevant_funcs, query_vec, top_k)

              :error ->
                []
            end

          {:ok, %{modules: top_modules, functions: function_results}}
      end
    end
  end

  defp rank_entries(entries, query_vec, top_k) when entries != [] do
    # Build matrix from stored binary vectors
    vectors =
      entries
      |> Enum.map(fn entry ->
        Nx.from_binary(entry.vector, :f32) |> Nx.reshape({@embedding_dims})
      end)
      |> Nx.stack()

    # Both are L2-normalized by EmbeddingServing, so cosine = dot product
    scores = Nx.dot(vectors, query_vec)

    # Get top-k indices
    {top_values, top_indices} = Nx.top_k(scores, k: min(top_k, length(entries)))

    top_values_list = Nx.to_flat_list(top_values)
    top_indices_list = Nx.to_flat_list(top_indices)

    Enum.zip(top_indices_list, top_values_list)
    |> Enum.map(fn {idx, score} ->
      entry = Enum.at(entries, trunc(idx))
      %{
        id: entry.id,
        score: Float.round(score, 4),
        metadata: entry.metadata
      }
    end)
  end

  defp rank_entries([], _query_vec, _top_k), do: []
end
