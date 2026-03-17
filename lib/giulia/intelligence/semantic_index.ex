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

  @skill_routers [
    Giulia.Daemon.Routers.Discovery,
    Giulia.Daemon.Routers.Approval,
    Giulia.Daemon.Routers.Transaction,
    Giulia.Daemon.Routers.Index,
    Giulia.Daemon.Routers.Search,
    Giulia.Daemon.Routers.Intelligence,
    Giulia.Daemon.Routers.Runtime,
    Giulia.Daemon.Routers.Knowledge,
    Giulia.Daemon.Routers.Monitor
  ]

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
  Search skills by semantic similarity to a query vector.
  Returns top_k skills ranked by cosine similarity.
  Lazy-inits skill vectors on first call if needed.
  """
  def search_skills(query_vector, top_k \\ 5) do
    GenServer.call(__MODULE__, {:search_skills, query_vector, top_k}, 30_000)
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
    {:ok, %{embedding_in_progress: MapSet.new(), skill_vectors: nil}}
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
    # Persist embeddings to CubDB (Build 102-104)
    for type <- [:module, :function] do
      case Store.get_embeddings(project_path, type) do
        {:ok, entries} ->
          Giulia.Persistence.Writer.persist_embeddings(project_path, type, entries)
        :error ->
          :ok
      end
    end

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

  @impl true
  def handle_call({:search_skills, query_vector, top_k}, _from, state) do
    # Lazy-init skill vectors if needed
    state =
      if state.skill_vectors == nil do
        case do_embed_skills() do
          {:ok, vectors} -> %{state | skill_vectors: vectors}
          {:error, _} -> state
        end
      else
        state
      end

    case state.skill_vectors do
      nil ->
        {:reply, {:error, "Skill embedding unavailable"}, state}

      [] ->
        {:reply, {:ok, []}, state}

      skill_data ->
        result = compute_skill_ranking(skill_data, query_vector, top_k)
        {:reply, {:ok, result}, state}
    end
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
          |> Enum.filter(&(&1.type in [:def, :defmacro, :defdelegate, :defguard]))
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
      |> Enum.filter(&(&1.type in [:def, :defmacro, :defdelegate, :defguard]))
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

  # ============================================================================
  # Semantic Duplicate Detection (Build 89)
  # ============================================================================

  @doc """
  Find semantically similar function pairs using pairwise cosine similarity.

  Algorithm:
  1. Load all function embeddings from ETS
  2. Stack into Nx tensor (n x 384)
  3. Full pairwise similarity: Nx.dot(M, M^T) — L2-normalized, so dot = cosine
  4. Extract upper-triangle pairs >= threshold
  5. Build connected components (BFS) to cluster duplicates

  Returns clusters sorted by avg internal similarity.
  """
  @spec find_duplicates(String.t(), keyword()) ::
          {:ok, %{clusters: [map()], count: non_neg_integer()}} | {:error, String.t()}
  def find_duplicates(project_path, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.85)
    max_clusters = Keyword.get(opts, :max, 20)

    unless EmbeddingServing.available?() do
      {:error, "Semantic search unavailable. EmbeddingServing not loaded."}
    else
      case Store.get_embeddings(project_path, :function) do
        :error ->
          {:error, "No embeddings for this project. Run /api/index/scan first."}

        {:ok, []} ->
          {:ok, %{clusters: [], count: 0}}

        {:ok, entries} ->
          # Build matrix from stored binary vectors
          vectors =
            entries
            |> Enum.map(fn entry ->
              Nx.from_binary(entry.vector, :f32) |> Nx.reshape({@embedding_dims})
            end)
            |> Nx.stack()

          # Full pairwise cosine similarity (L2-normalized → dot = cosine)
          similarity_matrix = Nx.dot(vectors, Nx.transpose(vectors))

          # Extract upper-triangle pairs above threshold
          n = length(entries)
          pairs = extract_similar_pairs(similarity_matrix, entries, n, threshold)

          # Build connected components via BFS
          clusters = build_clusters(pairs, entries)

          # Filter clusters below the requested threshold (BFS can create
          # transitive mega-clusters where A~B and B~C but A≁C) then sort
          clusters =
            clusters
            |> Enum.filter(fn c -> c.avg_similarity >= threshold end)
            |> Enum.sort_by(fn c -> -c.avg_similarity end)
            |> Enum.take(max_clusters)

          {:ok, %{clusters: clusters, count: length(clusters)}}
      end
    end
  end

  defp extract_similar_pairs(similarity_matrix, _entries, n, threshold) do
    for i <- 0..(n - 2),
        j <- (i + 1)..(n - 1),
        reduce: [] do
      acc ->
        score = similarity_matrix[i][j] |> Nx.to_number()

        if score >= threshold do
          [{i, j, Float.round(score, 4)} | acc]
        else
          acc
        end
    end
  end

  defp build_clusters(pairs, entries) do
    # Build adjacency list
    adjacency =
      Enum.reduce(pairs, %{}, fn {i, j, _score}, adj ->
        adj
        |> Map.update(i, MapSet.new([j]), &MapSet.put(&1, j))
        |> Map.update(j, MapSet.new([i]), &MapSet.put(&1, i))
      end)

    # BFS to find connected components
    all_nodes = Map.keys(adjacency) |> MapSet.new()
    {components, _visited} = bfs_components(adjacency, all_nodes)

    # Build cluster info
    pair_scores = Map.new(pairs, fn {i, j, score} -> {{i, j}, score} end)

    Enum.map(components, fn component ->
      members =
        component
        |> Enum.sort()
        |> Enum.map(fn idx ->
          entry = Enum.at(entries, idx)
          %{id: entry.id, metadata: entry.metadata}
        end)

      # Compute avg similarity within cluster
      component_list = Enum.sort(component)
      sim_scores =
        for i <- component_list,
            j <- component_list,
            i < j do
          key = {min(i, j), max(i, j)}
          Map.get(pair_scores, key, 0.0)
        end

      avg_sim =
        if sim_scores == [] do
          0.0
        else
          Float.round(Enum.sum(sim_scores) / length(sim_scores), 4)
        end

      %{
        members: members,
        size: length(members),
        avg_similarity: avg_sim
      }
    end)
    |> Enum.filter(fn c -> c.size >= 2 end)
  end

  defp bfs_components(adjacency, all_nodes) do
    Enum.reduce(all_nodes, {[], MapSet.new()}, fn node, {components, visited} ->
      if MapSet.member?(visited, node) do
        {components, visited}
      else
        {component, new_visited} = bfs(adjacency, node, visited)
        {[component | components], new_visited}
      end
    end)
  end

  defp bfs(adjacency, start, visited) do
    do_bfs(adjacency, [start], MapSet.new([start]), MapSet.put(visited, start))
  end

  defp do_bfs(_adjacency, [], component, visited), do: {MapSet.to_list(component), visited}

  defp do_bfs(adjacency, queue, component, visited) do
    next_queue =
      Enum.flat_map(queue, fn node ->
        neighbors = Map.get(adjacency, node, MapSet.new())
        MapSet.to_list(neighbors)
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_component = Enum.reduce(next_queue, component, &MapSet.put(&2, &1))
    new_visited = Enum.reduce(next_queue, visited, &MapSet.put(&2, &1))

    do_bfs(adjacency, next_queue, new_component, new_visited)
  end

  # ============================================================================
  # Skill Embedding (Build 100)
  # ============================================================================

  defp do_embed_skills do
    unless EmbeddingServing.available?() do
      {:error, "EmbeddingServing not available"}
    else
      skills = Enum.flat_map(@skill_routers, fn router ->
        try do
          router.__skills__()
        rescue
          _ -> []
        end
      end)

      if skills == [] do
        {:ok, []}
      else
        texts = Enum.map(skills, fn skill ->
          "#{skill.intent} — #{skill.endpoint}"
        end)

        vectors = embed_batch(texts)

        skill_data =
          Enum.zip(skills, vectors)
          |> Enum.map(fn {skill, vector} ->
            %{skill: skill, vector: vector}
          end)

        Logger.info("SemanticIndex: Embedded #{length(skill_data)} skill intents")
        {:ok, skill_data}
      end
    end
  end

  defp compute_skill_ranking(skill_data, query_vector, top_k) do
    vectors =
      skill_data
      |> Enum.map(fn %{vector: vec} ->
        Nx.from_binary(vec, :f32) |> Nx.reshape({@embedding_dims})
      end)
      |> Nx.stack()

    # Both L2-normalized by EmbeddingServing → cosine = dot product
    scores = Nx.dot(vectors, query_vector)

    k = min(top_k, length(skill_data))
    {top_values, top_indices} = Nx.top_k(scores, k: k)

    top_values_list = Nx.to_flat_list(top_values)
    top_indices_list = Nx.to_flat_list(top_indices)

    Enum.zip(top_indices_list, top_values_list)
    |> Enum.map(fn {idx, score} ->
      %{skill: skill} = Enum.at(skill_data, trunc(idx))

      skill
      |> Map.put(:relevance, Float.round(score, 4))
    end)
  end
end
