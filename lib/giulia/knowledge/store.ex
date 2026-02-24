defmodule Giulia.Knowledge.Store do
  @moduledoc """
  Knowledge Graph — Project Topology as a Directed Graph.

  Upgrades Giulia from a flat index (ETS lists of modules/functions) to a
  deterministic graph of relationships: who depends on whom, what calls what,
  what's the blast radius of a change.

  Uses libgraph (pure Elixir, no NIFs) for graph operations.

  All graph data is namespaced by project_path to support multi-project isolation.
  State: %{graphs: %{project_path => graph}, metric_caches: %{project_path => %{atom => term}}}

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

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Rebuild the entire knowledge graph from Context.Store AST data for a project.
  Called automatically after indexing completes.
  """
  @spec rebuild(project_path()) :: :ok
  def rebuild(project_path) when is_binary(project_path) do
    GenServer.cast(__MODULE__, {:rebuild, project_path})
  end

  @doc """
  Rebuild with a specific set of AST data (for testing or commit verification).
  """
  @spec rebuild(project_path(), %{String.t() => map()}) :: :ok
  def rebuild(project_path, ast_data) when is_binary(project_path) and is_map(ast_data) do
    GenServer.call(__MODULE__, {:rebuild, project_path, ast_data}, 30_000)
  end

  @doc """
  Get impact map for a module — who depends on it and what it depends on.
  """
  @spec impact_map(project_path(), vertex_id(), non_neg_integer()) :: {:ok, impact_map()} | {:error, {:not_found, vertex_id(), [vertex_id()], map()}}
  def impact_map(project_path, vertex_id, depth \\ 2) do
    GenServer.call(__MODULE__, {:impact_map, project_path, vertex_id, depth})
  end

  @doc """
  Trace the shortest path between two vertices.
  """
  @spec trace_path(project_path(), vertex_id(), vertex_id()) :: {:ok, [vertex_id()] | :no_path} | {:error, {:not_found, vertex_id()}}
  def trace_path(project_path, from, to) do
    GenServer.call(__MODULE__, {:trace_path, project_path, from, to})
  end

  @doc """
  Get modules that depend on the given module (downstream).
  """
  @spec dependents(project_path(), vertex_id()) :: {:ok, [vertex_id()]} | {:error, {:not_found, vertex_id()}}
  def dependents(project_path, module) do
    GenServer.call(__MODULE__, {:dependents, project_path, module})
  end

  @doc """
  Get modules that the given module depends on (upstream).
  """
  @spec dependencies(project_path(), vertex_id()) :: {:ok, [vertex_id()]} | {:error, {:not_found, vertex_id()}}
  def dependencies(project_path, module) do
    GenServer.call(__MODULE__, {:dependencies, project_path, module})
  end

  @doc """
  Get the degree centrality of a module — count of direct dependents (in-degree).
  Returns {:ok, %{in_degree: N, out_degree: N, dependents: [names]}} or {:error, :not_found}.
  Used by the Orchestrator's Hub Alarm to assess risk before approving edits.
  """
  @spec centrality(project_path(), vertex_id()) :: {:ok, centrality_info()} | {:error, :not_found}
  def centrality(project_path, module) do
    GenServer.call(__MODULE__, {:centrality, project_path, module})
  end

  @doc """
  Get test targets for a module — its own test file plus tests for direct dependents.
  Used by the Orchestrator's auto-regression to run only the tests that matter.
  Returns {:ok, %{direct: path, dependents: [{module, path}], all_paths: [paths]}}
  """
  @spec get_test_targets(project_path(), vertex_id()) :: {:ok, test_targets()} | {:error, :not_found}
  def get_test_targets(project_path, module) do
    GenServer.call(__MODULE__, {:test_targets, project_path, module})
  end

  @doc """
  Check behaviour-implementer consistency for a specific behaviour module.
  Returns {:ok, :consistent} or {:error, fractures}.
  """
  @spec check_behaviour_integrity(project_path(), vertex_id()) :: {:ok, :consistent} | {:error, :not_found | [map()]}
  def check_behaviour_integrity(project_path, behaviour_module) do
    GenServer.call(__MODULE__, {:check_behaviour_integrity, project_path, behaviour_module})
  end

  @doc """
  Check all behaviours in the project for implementer consistency.
  Returns {:ok, :consistent} or {:error, %{behaviour => [fracture]}}.
  """
  @spec check_all_behaviours(project_path()) :: {:ok, :consistent} | {:error, %{vertex_id() => [map()]}}
  def check_all_behaviours(project_path) do
    GenServer.call(__MODULE__, {:check_all_behaviours, project_path}, 30_000)
  end

  @doc """
  Find dead code — functions that are defined but never called anywhere.
  Returns {:ok, %{dead: [%{module, name, arity, type, file, line}], count: N, total: N}}.
  """
  @spec find_dead_code(project_path()) :: {:ok, %{dead: [map()], count: non_neg_integer(), total: non_neg_integer()}}
  def find_dead_code(project_path) do
    GenServer.call(__MODULE__, {:find_dead_code, project_path}, 30_000)
  end

  @doc """
  Find circular dependencies using strongly connected components.
  Returns {:ok, %{cycles: [[module_name]], count: N}}.
  """
  @spec find_cycles(project_path()) :: {:ok, %{cycles: [[vertex_id()]], count: non_neg_integer()}}
  def find_cycles(project_path) do
    GenServer.call(__MODULE__, {:find_cycles, project_path}, 30_000)
  end

  @doc """
  Find god modules — high function count + high complexity + high centrality.
  Returns {:ok, %{modules: [%{module, functions, complexity, centrality, score, file}], count: N}}.
  """
  @spec find_god_modules(project_path()) :: {:ok, %{modules: [map()], count: non_neg_integer()}}
  def find_god_modules(project_path) do
    GenServer.call(__MODULE__, {:find_god_modules, project_path}, 30_000)
  end

  @doc """
  Find orphan specs — @spec declarations that don't match any defined function.
  Returns {:ok, %{orphans: [%{module, spec_function, spec_arity, line, file}], count: N}}.
  """
  @spec find_orphan_specs(project_path()) :: {:ok, %{orphans: [map()], count: non_neg_integer()}}
  def find_orphan_specs(project_path) do
    GenServer.call(__MODULE__, {:find_orphan_specs, project_path}, 30_000)
  end

  @doc """
  Fan-in/fan-out analysis — modules with too many incoming or outgoing dependencies.
  Returns {:ok, %{modules: [%{module, fan_in, fan_out, total, file}], count: N}}.
  """
  @spec find_fan_in_out(project_path()) :: {:ok, %{modules: [map()], count: non_neg_integer()}}
  def find_fan_in_out(project_path) do
    GenServer.call(__MODULE__, {:find_fan_in_out, project_path}, 30_000)
  end

  @doc """
  Coupling score — how many functions in A call functions in B, quantified per pair.
  Returns {:ok, %{pairs: [%{caller, callee, call_count, functions}], count: N}}.
  """
  @spec find_coupling(project_path()) :: {:ok, %{pairs: [map()], count: non_neg_integer()}}
  def find_coupling(project_path) do
    GenServer.call(__MODULE__, {:find_coupling, project_path}, 30_000)
  end

  @doc """
  API surface analysis — ratio of public to private functions per module.
  Returns {:ok, %{modules: [%{module, public, private, total, ratio, file}], count: N}}.
  """
  @spec find_api_surface(project_path()) :: {:ok, %{modules: [map()], count: non_neg_integer()}}
  def find_api_surface(project_path) do
    GenServer.call(__MODULE__, {:find_api_surface, project_path}, 30_000)
  end

  @doc """
  Change risk score — composite of centrality, complexity, fan-in, fan-out,
  coupling, and API surface. Single prioritized refactoring list.
  Returns {:ok, %{modules: [%{module, score, breakdown, file}], count: N}}.
  """
  @spec change_risk_score(project_path()) :: {:ok, %{modules: [map()], count: non_neg_integer()}}
  def change_risk_score(project_path) do
    GenServer.call(__MODULE__, {:change_risk_score, project_path}, 30_000)
  end

  @doc """
  Get graph statistics for a project.
  """
  @spec stats(project_path()) :: graph_stats()
  def stats(project_path) do
    GenServer.call(__MODULE__, {:stats, project_path})
  end

  @doc """
  Get the raw graph for a project (for debugging).
  """
  @spec graph(project_path()) :: Graph.t()
  def graph(project_path) do
    GenServer.call(__MODULE__, {:graph, project_path})
  end

  @doc """
  Add a semantic edge to the knowledge graph.
  Used by SemanticIndex to record concept-level relationships.
  """
  @spec add_semantic_edge(project_path(), vertex_id(), vertex_id(), String.t()) :: :ok
  def add_semantic_edge(project_path, from, to, reason) do
    GenServer.call(__MODULE__, {:add_semantic_edge, project_path, from, to, reason})
  end

  @doc """
  Get implementers of a behaviour module.
  """
  @spec get_implementers(project_path(), vertex_id()) :: {:ok, [vertex_id()]}
  def get_implementers(project_path, behaviour) do
    GenServer.call(__MODULE__, {:get_implementers, project_path, behaviour})
  end

  @doc """
  Trace the function-call path between two MFA vertices.
  Uses Dijkstra on the enriched graph (Pass 4 function-call edges).
  """
  @spec logic_flow(project_path(), String.t(), String.t()) ::
          {:ok, [map()]} | {:ok, :no_path} | {:error, {:not_found, String.t()}}
  def logic_flow(project_path, from_mfa, to_mfa) do
    GenServer.call(__MODULE__, {:logic_flow, project_path, from_mfa, to_mfa}, 30_000)
  end

  @doc """
  Find exemplar functions matching a concept query.
  Quality gate: only functions with both @spec and @doc.
  """
  @spec style_oracle(project_path(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def style_oracle(project_path, query, top_k \\ 3) do
    GenServer.call(__MODULE__, {:style_oracle, project_path, query, top_k}, 30_000)
  end

  @doc """
  Pre-impact check for rename/remove operations.
  Returns affected callers, risk score, and suggested phases.
  """
  @spec pre_impact_check(project_path(), map()) :: {:ok, map()} | {:error, term()}
  def pre_impact_check(project_path, params) do
    GenServer.call(__MODULE__, {:pre_impact_check, project_path, params}, 30_000)
  end

  @doc """
  Heatmap of module health — composite score from centrality, complexity,
  test coverage, and coupling.
  """
  @spec heatmap(project_path()) :: {:ok, map()}
  def heatmap(project_path) do
    GenServer.call(__MODULE__, {:heatmap, project_path}, 30_000)
  end

  @doc """
  Find hub modules with insufficient spec/doc coverage.
  Returns modules sorted by severity (red first) with spec/doc ratios.
  """
  @spec find_unprotected_hubs(project_path(), keyword()) ::
          {:ok, %{modules: [map()], count: non_neg_integer(), severity_counts: map()}}
  def find_unprotected_hubs(project_path, opts \\ []) do
    GenServer.call(__MODULE__, {:find_unprotected_hubs, project_path, opts}, 30_000)
  end

  @doc """
  Map struct data flow across modules: creators, consumers, logic leaks.
  Optionally filter to a single struct module.
  """
  @spec struct_lifecycle(project_path(), String.t() | nil) ::
          {:ok, %{structs: [map()], count: non_neg_integer()}}
  def struct_lifecycle(project_path, struct_module \\ nil) do
    GenServer.call(__MODULE__, {:struct_lifecycle, project_path, struct_module}, 30_000)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{graphs: %{}, metric_caches: %{}}}
  end

  # Helper to get graph for a project, defaulting to empty
  defp get_graph(state, project_path) do
    Map.get(state.graphs, project_path, Graph.new(type: :directed))
  end

  defp put_graph(state, project_path, graph) do
    %{state | graphs: Map.put(state.graphs, project_path, graph)}
  end

  # Metric cache helpers (Build 97)
  defp get_cached(state, project_path, metric) do
    get_in(state, [:metric_caches, project_path, metric])
  end

  defp put_metrics(state, project_path, metrics) do
    current = Map.get(state.metric_caches, project_path, %{})
    merged = Map.merge(current, metrics)
    %{state | metric_caches: Map.put(state.metric_caches, project_path, merged)}
  end

  defp clear_metrics(state, project_path) do
    %{state | metric_caches: Map.delete(state.metric_caches, project_path)}
  end

  @impl true
  def handle_cast({:rebuild, project_path}, state) do
    ast_data = Giulia.Context.Store.all_asts(project_path)
    store_pid = self()

    # Spawn graph construction off the GenServer process so the mailbox
    # stays responsive to queries while the CPU chews on AST nodes.
    Task.start(fn ->
      graph = Builder.build_graph(ast_data)
      GenServer.cast(store_pid, {:graph_ready, project_path, graph})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:graph_ready, project_path, graph}, state) do
    vertex_count = Graph.num_vertices(graph)
    edge_count = Graph.num_edges(graph)
    Logger.info("Knowledge graph rebuilt for #{project_path}: #{vertex_count} vertices, #{edge_count} edges")

    state =
      state
      |> put_graph(project_path, graph)
      |> clear_metrics(project_path)

    # Eagerly compute heavy metrics in background (same Task pattern as graph build).
    # Results arrive via {:metrics_ready, ...} cast — mailbox stays responsive.
    store_pid = self()

    Task.start(fn ->
      metrics = Analyzer.compute_cached_metrics(graph, project_path)
      GenServer.cast(store_pid, {:metrics_ready, project_path, metrics})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:metrics_ready, project_path, metrics}, state) do
    Logger.info("Metric cache warmed for #{project_path}: #{Map.keys(metrics) |> Enum.join(", ")}")
    {:noreply, put_metrics(state, project_path, metrics)}
  end

  @impl true
  def handle_call({:rebuild, project_path, ast_data}, _from, state) do
    # Synchronous rebuild for commit verification — caller chose to wait.
    # Clear cache but don't eagerly recompute (caller is in commit pipeline, speed matters).
    graph = Builder.build_graph(ast_data)
    state = state |> put_graph(project_path, graph) |> clear_metrics(project_path)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:impact_map, project_path, vertex_id, depth}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.impact_map(graph, vertex_id, depth)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:trace_path, project_path, from, to}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.trace_path(graph, from, to)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependents, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.dependents(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependencies, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.dependencies(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:centrality, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.centrality(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:test_targets, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.test_targets(graph, module, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_behaviour_integrity, project_path, behaviour}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.behaviour_integrity(graph, behaviour, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_all_behaviours, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.all_behaviours(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_implementers, project_path, behaviour}, _from, state) do
    graph = get_graph(state, project_path)
    implementers =
      Graph.in_edges(graph, behaviour)
      |> Enum.filter(fn edge -> edge.label == :implements end)
      |> Enum.map(fn edge -> edge.v1 end)
      |> Enum.uniq()

    {:reply, {:ok, implementers}, state}
  end

  @impl true
  def handle_call({:find_dead_code, project_path}, _from, state) do
    case get_cached(state, project_path, :dead_code) do
      nil ->
        graph = get_graph(state, project_path)
        result = Analyzer.dead_code(graph, project_path)
        {:reply, result, put_metrics(state, project_path, %{dead_code: result})}

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_call({:find_cycles, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.cycles(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_god_modules, project_path}, _from, state) do
    case get_cached(state, project_path, :god_modules) do
      nil ->
        graph = get_graph(state, project_path)
        result = Analyzer.god_modules(graph, project_path)
        {:reply, result, put_metrics(state, project_path, %{god_modules: result})}

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_call({:find_orphan_specs, project_path}, _from, state) do
    result = Analyzer.orphan_specs(project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_fan_in_out, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.fan_in_out(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_coupling, project_path}, _from, state) do
    case get_cached(state, project_path, :coupling) do
      nil ->
        result = Analyzer.coupling(project_path)
        {:reply, result, put_metrics(state, project_path, %{coupling: result})}

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_call({:find_api_surface, project_path}, _from, state) do
    result = Analyzer.api_surface(project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:change_risk_score, project_path}, _from, state) do
    case get_cached(state, project_path, :change_risk) do
      nil ->
        graph = get_graph(state, project_path)
        result = Analyzer.change_risk(graph, project_path)
        {:reply, result, put_metrics(state, project_path, %{change_risk: result})}

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_call({:stats, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.stats(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:graph, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    {:reply, graph, state}
  end

  @impl true
  def handle_call({:add_semantic_edge, project_path, from, to, reason}, _from, state) do
    graph = get_graph(state, project_path)
    new_graph = Graph.add_edge(graph, from, to, label: {:semantic, reason})
    {:reply, :ok, put_graph(state, project_path, new_graph)}
  end

  @impl true
  def handle_call({:logic_flow, project_path, from_mfa, to_mfa}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.logic_flow(graph, project_path, from_mfa, to_mfa)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:style_oracle, project_path, query, top_k}, _from, state) do
    result = Analyzer.style_oracle(project_path, query, top_k)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:pre_impact_check, project_path, params}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.pre_impact_check(graph, project_path, params)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:heatmap, project_path}, _from, state) do
    case get_cached(state, project_path, :heatmap) do
      nil ->
        graph = get_graph(state, project_path)
        result = Analyzer.heatmap(graph, project_path)
        {:reply, result, put_metrics(state, project_path, %{heatmap: result})}

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_call({:find_unprotected_hubs, project_path, opts}, _from, state) do
    graph = get_graph(state, project_path)
    result = Analyzer.find_unprotected_hubs(graph, project_path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:struct_lifecycle, project_path, struct_module}, _from, state) do
    result = Analyzer.struct_lifecycle(project_path, struct_module)
    {:reply, result, state}
  end

  # ============================================================================
  # Graph construction: delegated to Giulia.Knowledge.Builder
  # Query implementation: delegated to Giulia.Knowledge.Analyzer
  # ============================================================================
end
