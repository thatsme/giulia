defmodule Giulia.Knowledge.Store do
  @moduledoc """
  Knowledge Graph — Project Topology as a Directed Graph.

  Write coordinator + read facade. All graph data lives in ETS
  (`:giulia_knowledge_graphs`) with `read_concurrency: true` for
  concurrent reads. The GenServer exists only to serialize writes
  (rebuild, restore, semantic edge insertion).

  Read queries are delegated to `Store.Reader` which accesses ETS directly,
  bypassing the GenServer mailbox entirely.

  Vertex types (via labels):
  - :module    — e.g. "Giulia.Tools.EditFile"
  - :function  — e.g. "Giulia.Tools.EditFile.execute/2"
  - :struct    — e.g. "Giulia.Tools.EditFile" (same name, different label)
  - :behaviour — e.g. "Giulia.Tools.Registry" (defines @callback)

  Edge types (via labels):
  - :depends_on  — Module A imports/aliases/uses Module B
  - :calls       — Function A calls Function B (from xref)
  - :implements  — Module implements a behaviour (@behaviour)
  - :references  — Module references a struct from another module
  """
  use GenServer

  require Logger

  alias Giulia.Knowledge.Analyzer
  alias Giulia.Knowledge.Builder
  alias Giulia.Knowledge.Store.Reader

  @table :giulia_knowledge_graphs

  @type project_path :: String.t()
  @type vertex_id :: String.t()
  @type impact_map :: %{
          vertex: vertex_id(),
          upstream: [{vertex_id(), non_neg_integer()}],
          downstream: [{vertex_id(), non_neg_integer()}],
          function_edges: [{String.t(), [vertex_id()]}],
          depth: non_neg_integer()
        }
  @type graph_stats :: %{
          vertices: non_neg_integer(),
          edges: non_neg_integer(),
          components: non_neg_integer(),
          type_counts: map(),
          hubs: [{vertex_id(), non_neg_integer()}]
        }
  @type centrality_info :: %{in_degree: non_neg_integer(), out_degree: non_neg_integer(), dependents: [vertex_id()]}
  @type test_targets :: %{direct: String.t() | nil, dependents: [{vertex_id(), String.t()}], all_paths: [String.t()]}

  # ============================================================================
  # Client API — Writes (GenServer)
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Rebuild the entire knowledge graph from Context.Store AST data (async)."
  @spec rebuild(project_path()) :: :ok
  def rebuild(project_path) when is_binary(project_path) do
    GenServer.cast(__MODULE__, {:rebuild, project_path})
  end

  @doc "Rebuild with a specific set of AST data (sync, for testing/commit verification)."
  @spec rebuild(project_path(), %{String.t() => map()}) :: :ok
  def rebuild(project_path, ast_data) when is_binary(project_path) and is_map(ast_data) do
    GenServer.call(__MODULE__, {:rebuild, project_path, ast_data}, 30_000)
  end

  @doc "Add a semantic edge to the knowledge graph."
  @spec add_semantic_edge(project_path(), vertex_id(), vertex_id(), String.t()) :: :ok
  def add_semantic_edge(project_path, from, to, reason) do
    GenServer.call(__MODULE__, {:add_semantic_edge, project_path, from, to, reason})
  end

  @doc """
  Restore a previously persisted knowledge graph (called by Loader
  during warm start). Synchronous so callers can rely on the graph
  being visible in ETS (and thus in `list_projects/0`) once it
  returns — the warm-restore path depends on this ordering.
  """
  @spec restore_graph(project_path(), term()) :: :ok
  def restore_graph(project_path, graph) do
    GenServer.call(__MODULE__, {:restore_graph, project_path, graph})
  end

  @doc """
  Restore previously persisted metric caches. Synchronous for the
  same reason as `restore_graph/2` — downstream code may read the
  metrics immediately after restore returns.
  """
  @spec restore_metrics(project_path(), map()) :: :ok
  def restore_metrics(project_path, metrics) do
    GenServer.call(__MODULE__, {:restore_metrics, project_path, metrics})
  end

  # ============================================================================
  # Client API — Reads (delegated to Reader, bypass GenServer)
  # ============================================================================

  @spec stats(project_path()) :: graph_stats()
  defdelegate stats(project_path), to: Reader

  @spec centrality(project_path(), vertex_id()) :: {:ok, centrality_info()} | {:error, {:not_found, vertex_id()}}
  defdelegate centrality(project_path, module), to: Reader

  @spec dependents(project_path(), vertex_id()) :: {:ok, [vertex_id()]} | {:error, {:not_found, vertex_id()}}
  defdelegate dependents(project_path, module), to: Reader

  @spec dependencies(project_path(), vertex_id()) :: {:ok, [vertex_id()]} | {:error, {:not_found, vertex_id()}}
  defdelegate dependencies(project_path, module), to: Reader

  @spec trace_path(project_path(), vertex_id(), vertex_id()) :: {:ok, :no_path | [vertex_id()]} | {:error, {:not_found, vertex_id()}}
  defdelegate trace_path(project_path, from, to), to: Reader

  @spec find_cycles(project_path()) :: {:ok, map()}
  defdelegate find_cycles(project_path), to: Reader

  @spec find_fan_in_out(project_path()) :: {:ok, map()}
  defdelegate find_fan_in_out(project_path), to: Reader

  @spec find_dead_code(project_path()) :: {:ok, map()}
  defdelegate find_dead_code(project_path), to: Reader

  @spec find_god_modules(project_path()) :: {:ok, map()}
  defdelegate find_god_modules(project_path), to: Reader

  @spec find_orphan_specs(project_path()) :: {:ok, map()}
  defdelegate find_orphan_specs(project_path), to: Reader

  @spec find_coupling(project_path()) :: {:ok, map()}
  defdelegate find_coupling(project_path), to: Reader

  @spec find_api_surface(project_path()) :: {:ok, map()}
  defdelegate find_api_surface(project_path), to: Reader

  @spec heatmap(project_path()) :: {:ok, map()}
  defdelegate heatmap(project_path), to: Reader

  @spec change_risk_score(project_path()) :: {:ok, map()}
  defdelegate change_risk_score(project_path), to: Reader

  @spec get_test_targets(project_path(), vertex_id()) :: {:ok, test_targets()} | {:error, term()}
  defdelegate get_test_targets(project_path, module), to: Reader

  @spec check_behaviour_integrity(project_path(), vertex_id()) :: {:ok, :consistent} | {:error, :not_found | [map()]}
  defdelegate check_behaviour_integrity(project_path, behaviour), to: Reader

  @spec check_all_behaviours(project_path()) :: {:ok, :consistent} | {:error, map()}
  defdelegate check_all_behaviours(project_path), to: Reader

  @spec all_modules(project_path()) :: {:ok, [map()]}
  defdelegate all_modules(project_path), to: Reader

  @spec all_functions(project_path()) :: {:ok, [map()]}
  defdelegate all_functions(project_path), to: Reader

  @spec all_dependencies(project_path()) :: {:ok, [{vertex_id(), vertex_id(), atom()}]}
  defdelegate all_dependencies(project_path), to: Reader

  @spec all_dependencies_with_rollup(project_path()) ::
          {:ok, [{vertex_id(), vertex_id(), atom()}]}
  defdelegate all_dependencies_with_rollup(project_path), to: Reader

  @spec all_function_call_edges(project_path()) :: {:ok, [{vertex_id(), vertex_id(), atom()}]}
  defdelegate all_function_call_edges(project_path), to: Reader

  @spec all_function_call_edges_with_via(project_path()) ::
          {:ok, [{vertex_id(), vertex_id(), atom(), atom()}]}
  defdelegate all_function_call_edges_with_via(project_path), to: Reader

  @spec graph(project_path()) :: Graph.t()
  defdelegate graph(project_path), to: Reader

  @spec get_implementers(project_path(), vertex_id()) :: {:ok, [vertex_id()]}
  defdelegate get_implementers(project_path, behaviour), to: Reader

  @spec pre_impact_check(project_path(), map()) :: {:ok, map()}
  defdelegate pre_impact_check(project_path, params), to: Reader

  # Default-arg wrappers (defdelegate can't express defaults)
  @spec impact_map(project_path(), vertex_id(), non_neg_integer()) :: {:ok, impact_map()} | {:error, {:not_found, vertex_id(), [vertex_id()], map()}}
  def impact_map(project_path, vertex_id, depth \\ 2) do
    Reader.impact_map(project_path, vertex_id, depth)
  end

  @spec style_oracle(project_path(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def style_oracle(project_path, query, top_k \\ 3) do
    Reader.style_oracle(project_path, query, top_k)
  end

  @spec find_unprotected_hubs(project_path(), keyword()) ::
          {:ok, %{modules: [map()], count: non_neg_integer(), severity_counts: map()}}
  def find_unprotected_hubs(project_path, opts \\ []) do
    Reader.find_unprotected_hubs(project_path, opts)
  end

  @spec struct_lifecycle(project_path(), String.t() | nil) ::
          {:ok, %{structs: [map()], count: non_neg_integer()}}
  def struct_lifecycle(project_path, struct_module \\ nil) do
    Reader.struct_lifecycle(project_path, struct_module)
  end

  @spec logic_flow(project_path(), String.t(), String.t()) ::
          {:ok, [map()]} | {:ok, :no_path} | {:error, {:not_found, String.t()}}
  def logic_flow(project_path, from_mfa, to_mfa) do
    Reader.logic_flow(project_path, from_mfa, to_mfa)
  end

  @spec find_conventions(project_path()) :: {:ok, map()}
  defdelegate find_conventions(project_path), to: Reader

  @spec find_conventions(project_path(), String.t() | keyword()) :: {:ok, map()}
  defdelegate find_conventions(project_path, module_filter_or_opts), to: Reader

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_) do
    Giulia.EtsKeeper.claim_or_new(@table)
    {:ok, %{}}
  end

  # --- Casts (async writes) ---

  @impl true
  def handle_cast({:rebuild, project_path}, state) do
    ast_data = Giulia.Context.Store.all_asts(project_path)
    store_pid = self()

    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      try do
        graph = Builder.build_graph(ast_data)
        GenServer.cast(store_pid, {:graph_ready, project_path, graph})
      rescue
        e ->
          Logger.error("Knowledge graph build failed: #{Exception.message(e)}")
          GenServer.cast(store_pid, {:graph_ready, project_path, Graph.new(type: :directed)})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:graph_ready, project_path, graph}, state) do
    vertex_count = Graph.num_vertices(graph)
    edge_count = Graph.num_edges(graph)
    Logger.info("Knowledge graph rebuilt for #{project_path}: #{vertex_count} vertices, #{edge_count} edges")

    ets_put_graph(project_path, graph)
    # Don't clear metrics here — keep serving old cache until new metrics are ready.
    # This prevents the race where a Reader cold-miss computes from the OLD graph
    # between cache clear and metrics_ready. Atomic swap happens in metrics_ready.

    # Persist graph to CubDB (Build 102-104)
    Giulia.Persistence.Writer.persist_graph(project_path, graph)

    # Notify ArcadeDB Indexer that the graph is ready. Async send/2 — if
    # Indexer is down or crashes mid-handle, the message vanishes
    # silently. The Indexer reconciles missed snapshots periodically
    # (see storage/arcade/indexer.ex), but we log misses here too so
    # they surface in operator logs without waiting for the next
    # reconcile tick.
    build_id = Giulia.Version.build()

    case GenServer.whereis(Giulia.Storage.Arcade.Indexer) do
      nil ->
        Logger.warning(
          "[Knowledge.Store] Arcade.Indexer not registered — snapshot for " <>
            "#{project_path}@#{build_id} deferred to next reconcile"
        )

      pid ->
        send(pid, {:graph_ready, project_path, build_id})
    end

    # Eagerly compute heavy metrics in background
    store_pid = self()

    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      metrics = Analyzer.compute_cached_metrics(graph, project_path)
      GenServer.cast(store_pid, {:metrics_ready, project_path, metrics})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:metrics_ready, project_path, metrics}, state) do
    Logger.info("Metric cache warmed for #{project_path}: #{Enum.join(Map.keys(metrics), ", ")}")

    # Atomic swap: replace entire cache (not merge) so stale entries can't survive
    ets_replace_metrics(project_path, metrics)

    # Persist metrics to CubDB (Build 102-104)
    Giulia.Persistence.Writer.persist_metrics(project_path, metrics)

    {:noreply, state}
  end

  @impl true
  def handle_call({:restore_graph, project_path, graph}, _from, state) do
    vertex_count = Graph.num_vertices(graph)
    edge_count = Graph.num_edges(graph)
    Logger.info("Knowledge graph restored from cache for #{project_path}: #{vertex_count} vertices, #{edge_count} edges")

    ets_put_graph(project_path, graph)

    {:reply, :ok, state}
  end

  def handle_call({:restore_metrics, project_path, metrics}, _from, state) do
    Logger.info("Metric cache restored from disk for #{project_path}: #{Enum.join(Map.keys(metrics), ", ")}")

    ets_put_metrics(project_path, metrics)

    {:reply, :ok, state}
  end

  # --- Calls (sync writes) ---

  @impl true
  def handle_call({:rebuild, project_path, ast_data}, _from, state) do
    graph =
      try do
        Builder.build_graph(ast_data)
      rescue
        e ->
          Logger.error("Knowledge graph build failed: #{Exception.message(e)}")
          Graph.new(type: :directed)
      end

    ets_put_graph(project_path, graph)
    # Sync rebuild: compute metrics inline and atomic-swap
    metrics = Analyzer.compute_cached_metrics(graph, project_path)
    ets_replace_metrics(project_path, metrics)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_semantic_edge, project_path, from, to, reason}, _from, state) do
    graph = ets_get_graph(project_path)
    new_graph = Graph.add_edge(graph, from, to, label: {:semantic, reason})
    ets_put_graph(project_path, new_graph)
    {:reply, :ok, state}
  end

  # ============================================================================
  # Private ETS write helpers
  # ============================================================================

  @doc "Return every project_path that has a graph stored in memory."
  @spec list_projects() :: [project_path()]
  def list_projects do
    @table
    |> :ets.match({{:graph, :"$1"}, :_})
    |> List.flatten()
  end

  defp ets_get_graph(project_path) do
    case :ets.lookup(@table, {:graph, project_path}) do
      [{_, graph}] -> graph
      [] -> Graph.new(type: :directed)
    end
  end

  defp ets_put_graph(project_path, graph) do
    :ets.insert(@table, {{:graph, project_path}, graph})
  end

  defp ets_put_metrics(project_path, metrics) do
    current =
      case :ets.lookup(@table, {:metrics, project_path}) do
        [{_, existing}] -> existing
        [] -> %{}
      end

    :ets.insert(@table, {{:metrics, project_path}, Map.merge(current, metrics)})
  end

  defp ets_replace_metrics(project_path, metrics) do
    :ets.insert(@table, {{:metrics, project_path}, metrics})
  end
end
