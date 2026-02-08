defmodule Giulia.Knowledge.Store do
  @moduledoc """
  Knowledge Graph — Project Topology as a Directed Graph.

  Upgrades Giulia from a flat index (ETS lists of modules/functions) to a
  deterministic graph of relationships: who depends on whom, what calls what,
  what's the blast radius of a change.

  Uses libgraph (pure Elixir, no NIFs) for graph operations.

  All graph data is namespaced by project_path to support multi-project isolation.
  State: %{graphs: %{project_path => graph}}

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

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Rebuild the entire knowledge graph from Context.Store AST data for a project.
  Called automatically after indexing completes.
  """
  def rebuild(project_path) when is_binary(project_path) do
    GenServer.cast(__MODULE__, {:rebuild, project_path})
  end

  @doc """
  Rebuild with a specific set of AST data (for testing or commit verification).
  """
  def rebuild(project_path, ast_data) when is_binary(project_path) and is_map(ast_data) do
    GenServer.call(__MODULE__, {:rebuild, project_path, ast_data}, 30_000)
  end

  @doc """
  Get impact map for a module — who depends on it and what it depends on.
  """
  def impact_map(project_path, vertex_id, depth \\ 2) do
    GenServer.call(__MODULE__, {:impact_map, project_path, vertex_id, depth})
  end

  @doc """
  Trace the shortest path between two vertices.
  """
  def trace_path(project_path, from, to) do
    GenServer.call(__MODULE__, {:trace_path, project_path, from, to})
  end

  @doc """
  Get modules that depend on the given module (downstream).
  """
  def dependents(project_path, module) do
    GenServer.call(__MODULE__, {:dependents, project_path, module})
  end

  @doc """
  Get modules that the given module depends on (upstream).
  """
  def dependencies(project_path, module) do
    GenServer.call(__MODULE__, {:dependencies, project_path, module})
  end

  @doc """
  Get the degree centrality of a module — count of direct dependents (in-degree).
  Returns {:ok, %{in_degree: N, out_degree: N, dependents: [names]}} or {:error, :not_found}.
  Used by the Orchestrator's Hub Alarm to assess risk before approving edits.
  """
  def centrality(project_path, module) do
    GenServer.call(__MODULE__, {:centrality, project_path, module})
  end

  @doc """
  Get test targets for a module — its own test file plus tests for direct dependents.
  Used by the Orchestrator's auto-regression to run only the tests that matter.
  Returns {:ok, %{direct: path, dependents: [{module, path}], all_paths: [paths]}}
  """
  def get_test_targets(project_path, module) do
    GenServer.call(__MODULE__, {:test_targets, project_path, module})
  end

  @doc """
  Check behaviour-implementer consistency for a specific behaviour module.
  Returns {:ok, :consistent} or {:error, fractures}.
  """
  def check_behaviour_integrity(project_path, behaviour_module) do
    GenServer.call(__MODULE__, {:check_behaviour_integrity, project_path, behaviour_module})
  end

  @doc """
  Check all behaviours in the project for implementer consistency.
  Returns {:ok, :consistent} or {:error, %{behaviour => [fracture]}}.
  """
  def check_all_behaviours(project_path) do
    GenServer.call(__MODULE__, {:check_all_behaviours, project_path}, 30_000)
  end

  @doc """
  Find dead code — functions that are defined but never called anywhere.
  Returns {:ok, %{dead: [%{module, name, arity, type, file, line}], count: N, total: N}}.
  """
  def find_dead_code(project_path) do
    GenServer.call(__MODULE__, {:find_dead_code, project_path}, 30_000)
  end

  @doc """
  Find circular dependencies using strongly connected components.
  Returns {:ok, %{cycles: [[module_name]], count: N}}.
  """
  def find_cycles(project_path) do
    GenServer.call(__MODULE__, {:find_cycles, project_path}, 30_000)
  end

  @doc """
  Find god modules — high function count + high complexity + high centrality.
  Returns {:ok, %{modules: [%{module, functions, complexity, centrality, score, file}], count: N}}.
  """
  def find_god_modules(project_path) do
    GenServer.call(__MODULE__, {:find_god_modules, project_path}, 30_000)
  end

  @doc """
  Find orphan specs — @spec declarations that don't match any defined function.
  Returns {:ok, %{orphans: [%{module, spec_function, spec_arity, line, file}], count: N}}.
  """
  def find_orphan_specs(project_path) do
    GenServer.call(__MODULE__, {:find_orphan_specs, project_path}, 30_000)
  end

  @doc """
  Fan-in/fan-out analysis — modules with too many incoming or outgoing dependencies.
  Returns {:ok, %{modules: [%{module, fan_in, fan_out, total, file}], count: N}}.
  """
  def find_fan_in_out(project_path) do
    GenServer.call(__MODULE__, {:find_fan_in_out, project_path}, 30_000)
  end

  @doc """
  Coupling score — how many functions in A call functions in B, quantified per pair.
  Returns {:ok, %{pairs: [%{caller, callee, call_count, functions}], count: N}}.
  """
  def find_coupling(project_path) do
    GenServer.call(__MODULE__, {:find_coupling, project_path}, 30_000)
  end

  @doc """
  API surface analysis — ratio of public to private functions per module.
  Returns {:ok, %{modules: [%{module, public, private, total, ratio, file}], count: N}}.
  """
  def find_api_surface(project_path) do
    GenServer.call(__MODULE__, {:find_api_surface, project_path}, 30_000)
  end

  @doc """
  Change risk score — composite of centrality, complexity, fan-in, fan-out,
  coupling, and API surface. Single prioritized refactoring list.
  Returns {:ok, %{modules: [%{module, score, breakdown, file}], count: N}}.
  """
  def change_risk_score(project_path) do
    GenServer.call(__MODULE__, {:change_risk_score, project_path}, 30_000)
  end

  @doc """
  Get graph statistics for a project.
  """
  def stats(project_path) do
    GenServer.call(__MODULE__, {:stats, project_path})
  end

  @doc """
  Get the raw graph for a project (for debugging).
  """
  def graph(project_path) do
    GenServer.call(__MODULE__, {:graph, project_path})
  end

  @doc """
  Get implementers of a behaviour module.
  """
  def get_implementers(project_path, behaviour) do
    GenServer.call(__MODULE__, {:get_implementers, project_path, behaviour})
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{graphs: %{}}}
  end

  # Helper to get graph for a project, defaulting to empty
  defp get_graph(state, project_path) do
    Map.get(state.graphs, project_path, Graph.new(type: :directed))
  end

  defp put_graph(state, project_path, graph) do
    %{state | graphs: Map.put(state.graphs, project_path, graph)}
  end

  @impl true
  def handle_cast({:rebuild, project_path}, state) do
    ast_data = Giulia.Context.Store.all_asts(project_path)
    graph = build_graph(ast_data)

    vertex_count = Graph.num_vertices(graph)
    edge_count = Graph.num_edges(graph)
    Logger.info("Knowledge graph rebuilt for #{project_path}: #{vertex_count} vertices, #{edge_count} edges")

    {:noreply, put_graph(state, project_path, graph)}
  end

  @impl true
  def handle_call({:rebuild, project_path, ast_data}, _from, state) do
    graph = build_graph(ast_data)
    {:reply, :ok, put_graph(state, project_path, graph)}
  end

  @impl true
  def handle_call({:impact_map, project_path, vertex_id, depth}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_impact_map(graph, vertex_id, depth)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:trace_path, project_path, from, to}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_trace_path(graph, from, to)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependents, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_dependents(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependencies, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_dependencies(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:centrality, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_centrality(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:test_targets, project_path, module}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_test_targets(graph, module, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_behaviour_integrity, project_path, behaviour}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_behaviour_integrity(graph, behaviour, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_all_behaviours, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_all_behaviours(graph, project_path)
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
    graph = get_graph(state, project_path)
    result = compute_dead_code(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_cycles, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_cycles(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_god_modules, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_god_modules(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_orphan_specs, project_path}, _from, state) do
    result = compute_orphan_specs(project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_fan_in_out, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_fan_in_out(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_coupling, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_coupling(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_api_surface, project_path}, _from, state) do
    result = compute_api_surface(project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:change_risk_score, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_change_risk(graph, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:stats, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    result = compute_stats(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:graph, project_path}, _from, state) do
    graph = get_graph(state, project_path)
    {:reply, graph, state}
  end

  # ============================================================================
  # Graph Construction
  # ============================================================================

  defp build_graph(ast_data) do
    graph = Graph.new(type: :directed)

    # Collect all module names for cross-referencing
    all_modules =
      ast_data
      |> Enum.flat_map(fn {_path, data} ->
        (data[:modules] || []) |> Enum.map(& &1.name)
      end)
      |> MapSet.new()

    # Pass 1: Add vertices
    graph = Enum.reduce(ast_data, graph, fn {_path, data}, g ->
      g
      |> add_module_vertices(data)
      |> add_function_vertices(data)
      |> add_struct_vertices(data)
      |> add_behaviour_vertices(data)
    end)

    # Pass 2: Add edges
    graph = Enum.reduce(ast_data, graph, fn {_path, data}, g ->
      g
      |> add_dependency_edges(data, all_modules)
      |> add_implements_edges(data, all_modules)
    end)

    # Pass 3: Add xref call edges (if compiled BEAM files exist)
    add_xref_edges(graph)
  end

  defp add_module_vertices(graph, data) do
    modules = data[:modules] || []

    Enum.reduce(modules, graph, fn mod, g ->
      Graph.add_vertex(g, mod.name, :module)
    end)
  end

  defp add_function_vertices(graph, data) do
    modules = data[:modules] || []
    functions = data[:functions] || []
    module_name = case modules do
      [first | _] -> first.name
      _ -> nil
    end

    if module_name do
      Enum.reduce(functions, graph, fn func, g ->
        vertex_id = "#{module_name}.#{func.name}/#{func.arity}"
        Graph.add_vertex(g, vertex_id, :function)
      end)
    else
      graph
    end
  end

  defp add_struct_vertices(graph, data) do
    structs = data[:structs] || []

    Enum.reduce(structs, graph, fn struct_info, g ->
      Graph.add_vertex(g, struct_info.module, :struct)
    end)
  end

  defp add_behaviour_vertices(graph, data) do
    callbacks = data[:callbacks] || []
    modules = data[:modules] || []

    if callbacks != [] do
      case modules do
        [first | _] ->
          Graph.add_vertex(graph, first.name, :behaviour)
        _ ->
          graph
      end
    else
      graph
    end
  end

  defp add_dependency_edges(graph, data, all_modules) do
    modules = data[:modules] || []
    imports = data[:imports] || []

    case modules do
      [source_mod | _] ->
        # ALL import types (import, alias, use, require) indicate a dependency
        Enum.reduce(imports, graph, fn imp, g ->
          # Only add edges to modules that exist in our project
          if MapSet.member?(all_modules, imp.module) and imp.module != source_mod.name do
            Graph.add_edge(g, source_mod.name, imp.module, label: :depends_on)
          else
            g
          end
        end)

      _ ->
        graph
    end
  end

  defp add_implements_edges(graph, data, all_modules) do
    modules = data[:modules] || []
    imports = data[:imports] || []

    case modules do
      [source_mod | _] ->
        # @behaviour / use directives indicate implementation
        behaviour_imports =
          imports
          |> Enum.filter(fn imp ->
            imp.type in [:use, :require] and MapSet.member?(all_modules, imp.module)
          end)

        Enum.reduce(behaviour_imports, graph, fn imp, g ->
          if imp.module != source_mod.name do
            Graph.add_edge(g, source_mod.name, imp.module, label: :implements)
          else
            g
          end
        end)

      _ ->
        graph
    end
  end

  defp add_xref_edges(graph) do
    # Try multiple approaches to find BEAM files
    beam_dir = find_beam_directory()

    if beam_dir do
      Logger.info("Found BEAM files at #{beam_dir}, running xref analysis")
      run_xref_analysis(graph, beam_dir)
    else
      Logger.debug("No BEAM directory found, skipping xref call edges")
      graph
    end
  end

  defp find_beam_directory do
    # Check common locations for compiled BEAM files
    candidates = [
      # Docker container build path
      "/tmp/giulia_build/lib/giulia/ebin",
      # Standard mix build
      "_build/dev/lib/giulia/ebin",
      # Production
      "_build/prod/lib/giulia/ebin"
    ]

    Enum.find(candidates, &File.dir?/1)
  end

  defp run_xref_analysis(graph, beam_dir) do
    try do
      # Dynamic calls to :xref to avoid compile warnings
      # (xref is in the Erlang 'tools' app, may not be available at compile time)
      xref_mod = :xref

      {:ok, xref} = apply(xref_mod, :start, [:giulia_xref, [{:xref_mode, :modules}]])

      apply(xref_mod, :add_directory, [xref, String.to_charlist(beam_dir)])

      case apply(xref_mod, :q, [xref, ~c"ME"]) do
        {:ok, calls} ->
          Logger.info("xref found #{length(calls)} module-level call edges")
          graph = add_module_call_edges(graph, calls)
          apply(xref_mod, :stop, [xref])
          graph

        {:error, _xref_mod, reason} ->
          Logger.warning("xref query failed: #{inspect(reason)}")
          apply(xref_mod, :stop, [xref])
          graph
      end
    rescue
      e ->
        Logger.debug("xref analysis failed: #{Exception.message(e)}")
        graph
    catch
      _, reason ->
        Logger.debug("xref analysis error: #{inspect(reason)}")
        graph
    end
  end

  # Add module-level call edges from xref results
  # xref ME query returns [{CallerMod, CalleeMod}]
  defp add_module_call_edges(graph, calls) when is_list(calls) do
    Enum.reduce(calls, graph, fn {caller_mod, callee_mod}, g ->
      caller = Atom.to_string(caller_mod) |> String.replace_leading("Elixir.", "")
      callee = Atom.to_string(callee_mod) |> String.replace_leading("Elixir.", "")

      if Graph.has_vertex?(g, caller) and Graph.has_vertex?(g, callee) and caller != callee do
        Graph.add_edge(g, caller, callee, label: :calls)
      else
        g
      end
    end)
  end

  defp add_module_call_edges(graph, _), do: graph

  # ============================================================================
  # Query Implementation
  # ============================================================================

  defp compute_impact_map(graph, vertex_id, depth) do
    if Graph.has_vertex?(graph, vertex_id) do
      # Upstream: what this vertex depends on (follow outgoing edges)
      upstream = collect_reachable(graph, vertex_id, :out, depth)

      # Downstream: what depends on this vertex (follow incoming edges)
      downstream = collect_reachable(graph, vertex_id, :in, depth)

      # Function-level details if this is a module
      function_edges = get_function_edges(graph, vertex_id)

      {:ok, %{
        vertex: vertex_id,
        upstream: upstream,
        downstream: downstream,
        function_edges: function_edges,
        depth: depth
      }}
    else
      # Fuzzy match: find top 5 similar vertices (modules only, not functions)
      vertices = Graph.vertices(graph)

      module_vertices = Enum.filter(vertices, fn v ->
        is_binary(v) and Graph.vertex_labels(graph, v) == [:module]
      end)

      needle = String.downcase(vertex_id)
      matches =
        module_vertices
        |> Enum.map(fn v -> {v, fuzzy_score(String.downcase(v), needle)} end)
        |> Enum.filter(fn {_v, score} -> score > 0 end)
        |> Enum.sort_by(fn {_v, score} -> -score end)
        |> Enum.take(5)
        |> Enum.map(fn {v, _score} -> v end)

      # Graph density check
      v_count = Graph.num_vertices(graph)
      e_count = Graph.num_edges(graph)
      sparse? = e_count < v_count

      {:error, {:not_found, vertex_id, matches, %{sparse: sparse?, vertices: v_count, edges: e_count}}}
    end
  end

  # Simple fuzzy scoring: substring match + bonus for matching final segment
  defp fuzzy_score(haystack, needle) do
    cond do
      haystack == needle -> 100
      String.contains?(haystack, needle) -> 50
      # Match the last segment (e.g. "parser" matches "Giulia.StructuredOutput" if it contains "parser")
      last_segment_match?(haystack, needle) -> 30
      # Any segment overlap
      segments_overlap?(haystack, needle) -> 10
      true -> 0
    end
  end

  defp last_segment_match?(haystack, needle) do
    h_parts = String.split(haystack, ".")
    n_parts = String.split(needle, ".")
    last_h = List.last(h_parts) || ""
    last_n = List.last(n_parts) || ""
    String.contains?(last_h, last_n) or String.contains?(last_n, last_h)
  end

  defp segments_overlap?(haystack, needle) do
    h_parts = String.split(haystack, ".") |> MapSet.new()
    n_parts = String.split(needle, ".")
    Enum.any?(n_parts, fn part ->
      Enum.any?(h_parts, fn hp -> String.contains?(hp, part) or String.contains?(part, hp) end)
    end)
  end

  defp collect_reachable(graph, vertex_id, direction, max_depth) do
    do_collect(graph, [vertex_id], direction, 0, max_depth, %{}, MapSet.new([vertex_id]))
    |> Enum.sort_by(fn {_v, depth} -> depth end)
  end

  defp do_collect(_graph, [], _direction, _current_depth, _max_depth, acc, _visited), do: Map.to_list(acc)
  defp do_collect(_graph, _frontier, _direction, current_depth, max_depth, acc, _visited)
       when current_depth >= max_depth, do: Map.to_list(acc)

  defp do_collect(graph, frontier, direction, current_depth, max_depth, acc, visited) do
    next_depth = current_depth + 1

    neighbors =
      frontier
      |> Enum.flat_map(fn v ->
        case direction do
          :out -> Graph.out_neighbors(graph, v)
          :in -> Graph.in_neighbors(graph, v)
        end
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_acc = Enum.reduce(neighbors, acc, fn v, a -> Map.put(a, v, next_depth) end)
    new_visited = Enum.reduce(neighbors, visited, fn v, vs -> MapSet.put(vs, v) end)

    do_collect(graph, neighbors, direction, next_depth, max_depth, new_acc, new_visited)
  end

  defp get_function_edges(graph, module_name) do
    # Find function vertices belonging to this module
    Graph.vertices(graph)
    |> Enum.filter(fn v ->
      is_binary(v) and String.starts_with?(v, module_name <> ".") and
        Graph.vertex_labels(graph, v) == [:function]
    end)
    |> Enum.map(fn func_vertex ->
      targets = Graph.out_neighbors(graph, func_vertex)
      short_name = String.replace_prefix(func_vertex, module_name <> ".", "")
      {short_name, targets}
    end)
    |> Enum.reject(fn {_name, targets} -> targets == [] end)
  end

  defp compute_centrality(graph, module) do
    if Graph.has_vertex?(graph, module) do
      dependents = Graph.in_neighbors(graph, module)
      dependencies = Graph.out_neighbors(graph, module)
      {:ok, %{
        in_degree: length(dependents),
        out_degree: length(dependencies),
        dependents: Enum.sort(dependents)
      }}
    else
      {:error, :not_found}
    end
  end

  defp compute_test_targets(graph, module, project_path) do
    if Graph.has_vertex?(graph, module) do
      # Find the source file for this module
      direct_test = module_to_test_path(module, project_path)

      # Get direct dependents (in-neighbors = modules that depend on this one)
      dependents = Graph.in_neighbors(graph, module)
        |> Enum.filter(fn v -> Graph.vertex_labels(graph, v) == [:module] end)

      # Map each dependent to its test file, keep only existing ones
      dependent_tests = dependents
        |> Enum.map(fn dep_mod ->
          test_path = module_to_test_path(dep_mod, project_path)
          {dep_mod, test_path}
        end)
        |> Enum.filter(fn {_mod, path} -> path != nil end)

      # Collect all unique test paths that actually exist
      all_paths = ([direct_test | Enum.map(dependent_tests, &elem(&1, 1))])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, %{
        direct: direct_test,
        dependents: dependent_tests,
        all_paths: all_paths
      }}
    else
      {:error, :not_found}
    end
  end

  # Convert a module name to its conventional test file path.
  # Returns the path if the file exists, nil otherwise.
  defp module_to_test_path(module_name, project_path) do
    # Look up the source file in the AST store
    case Giulia.Context.Store.find_module(project_path, module_name) do
      {:ok, %{file: source_file}} ->
        test_file = Giulia.Tools.RunTests.suggest_test_file(source_file)
        full_path = Path.join(project_path, test_file)
        if File.exists?(full_path), do: test_file, else: nil
      _ ->
        nil
    end
  end

  defp compute_trace_path(graph, from, to) do
    if not Graph.has_vertex?(graph, from) do
      {:error, {:not_found, from}}
    else
      if not Graph.has_vertex?(graph, to) do
        {:error, {:not_found, to}}
      else
        case Graph.dijkstra(graph, from, to) do
          nil -> {:ok, :no_path}
          path -> {:ok, path}
        end
      end
    end
  end

  defp compute_dependents(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # Who points TO this module (incoming edges) = who depends on me
      deps = Graph.in_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  defp compute_dependencies(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # What this module points TO (outgoing edges) = what I depend on
      deps = Graph.out_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  # ============================================================================
  # Behaviour Integrity Check
  # ============================================================================

  defp compute_behaviour_integrity(graph, behaviour, project_path) do
    if not Graph.has_vertex?(graph, behaviour) do
      {:error, :not_found}
    else
      # Get declared callbacks from ETS
      callbacks = Giulia.Context.Store.list_callbacks(project_path, behaviour)

      if callbacks == [] do
        # Not a behaviour (no callbacks declared)
        {:ok, :consistent}
      else
        callback_set =
          Enum.map(callbacks, fn cb ->
            {to_string(cb.function), cb.arity}
          end)
          |> MapSet.new()

        # Get implementers: modules with :implements edge pointing TO this behaviour
        implementers =
          Graph.in_edges(graph, behaviour)
          |> Enum.filter(fn edge -> edge.label == :implements end)
          |> Enum.map(fn edge -> edge.v1 end)
          |> Enum.uniq()

        # Check each implementer
        fractures =
          Enum.flat_map(implementers, fn impl_mod ->
            # Get public functions of the implementer
            impl_functions =
              Giulia.Context.Store.list_functions(project_path, impl_mod)
              |> Enum.filter(fn f -> f.type == :def end)
              |> Enum.map(fn f -> {to_string(f.name), f.arity} end)
              |> MapSet.new()

            # Find callbacks missing from implementer
            missing =
              callback_set
              |> MapSet.difference(impl_functions)
              |> MapSet.to_list()

            if missing == [] do
              []
            else
              [%{implementer: impl_mod, missing: missing}]
            end
          end)

        if fractures == [] do
          {:ok, :consistent}
        else
          {:error, fractures}
        end
      end
    end
  end

  defp compute_all_behaviours(graph, project_path) do
    # Find behaviour modules from ETS (modules that declare @callback).
    # We can't rely on :behaviour vertex labels because libgraph's add_vertex
    # is a no-op when the vertex already exists — so :module always wins.
    behaviour_modules =
      Giulia.Context.Store.list_callbacks(project_path)
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.filter(&Graph.has_vertex?(graph, &1))

    # Check each behaviour
    all_fractures =
      Enum.reduce(behaviour_modules, %{}, fn behaviour, acc ->
        case compute_behaviour_integrity(graph, behaviour, project_path) do
          {:error, fractures} when is_list(fractures) ->
            Map.put(acc, behaviour, fractures)

          _ ->
            acc
        end
      end)

    if map_size(all_fractures) == 0 do
      {:ok, :consistent}
    else
      {:error, all_fractures}
    end
  end

  # ============================================================================
  # Dead Code Detection
  # ============================================================================

  # OTP/framework callbacks that are invoked implicitly, never via direct calls
  @implicit_functions MapSet.new([
    # GenServer
    {"init", 1}, {"handle_call", 3}, {"handle_cast", 2}, {"handle_info", 2},
    {"handle_continue", 2}, {"terminate", 2}, {"code_change", 3},
    # Application
    {"start", 2}, {"stop", 1},
    # Supervisor
    {"child_spec", 1},
    # Plug
    {"call", 2},
    # Escript
    {"main", 1},
    # Ecto
    {"changeset", 1}, {"changeset", 2},
    # Tool behaviour (Giulia-specific)
    {"name", 0}, {"description", 0}, {"parameters", 0}
  ])

  defp compute_dead_code(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Step 1: Get all defined functions
    all_functions = Giulia.Context.Store.list_functions(project_path, nil)

    # Step 2: Build set of behaviour callback signatures per implementer module
    # If module X implements behaviour Y, all of Y's callbacks are implicit in X
    impl_callbacks = collect_behaviour_callbacks(graph, project_path)

    # Step 3: Walk all ASTs to find every function call
    called_functions = collect_all_calls(all_asts)

    # Step 4: Find dead functions
    dead =
      all_functions
      |> Enum.reject(fn func ->
        name_arity = {to_string(func.name), func.arity}

        # Skip implicit OTP/framework callbacks
        MapSet.member?(@implicit_functions, name_arity) or
          # Skip behaviour callback implementations
          MapSet.member?(impl_callbacks, {func.module, to_string(func.name), func.arity}) or
          # Skip if called remotely: Module.func/arity
          MapSet.member?(called_functions, {func.module, to_string(func.name), func.arity}) or
          # Skip if called locally within the same module: func/arity
          MapSet.member?(called_functions, {func.module, :local, to_string(func.name), func.arity}) or
          # Skip if called with any arity (for functions with defaults)
          called_with_any_arity?(called_functions, func)
      end)
      |> Enum.map(fn func ->
        %{
          module: func.module,
          name: to_string(func.name),
          arity: func.arity,
          type: func.type,
          file: func.file,
          line: func.line
        }
      end)
      |> Enum.sort_by(&{&1.module, &1.name, &1.arity})

    {:ok, %{dead: dead, count: length(dead), total: length(all_functions)}}
  end

  # For each module that implements a behaviour, collect the behaviour's callbacks
  # as {implementer_module, callback_name, callback_arity} — these are called implicitly
  defp collect_behaviour_callbacks(graph, project_path) do
    # Find all :implements edges: implementer --implements--> behaviour
    Graph.edges(graph)
    |> Enum.filter(fn edge -> edge.label == :implements end)
    |> Enum.reduce(MapSet.new(), fn edge, acc ->
      implementer = edge.v1
      behaviour = edge.v2

      # Get the behaviour's declared callbacks
      callbacks = Giulia.Context.Store.list_callbacks(project_path, behaviour)

      Enum.reduce(callbacks, acc, fn cb, set ->
        MapSet.put(set, {implementer, to_string(cb.function), cb.arity})
      end)
    end)
  end

  # Walk all source files to collect function calls: remote (Module.func) and local (func)
  defp collect_all_calls(all_asts) do
    Enum.reduce(all_asts, MapSet.new(), fn {path, data}, acc ->
      modules = data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

      # Read source from disk — ETS stores metadata, not raw source
      source = case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end

      case Sourceror.parse_string(source) do
        {:ok, ast} ->
          {_ast, calls} =
            Macro.prewalk(ast, acc, fn
              # Remote call: Module.func(args)
              {{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args} = node, set
              when is_atom(func_name) and is_list(args) ->
                mod = Enum.map_join(parts, ".", &to_string/1)
                {node, MapSet.put(set, {mod, to_string(func_name), length(args)})}

              # Remote call with full Elixir module: Elixir.Module.func(args)
              {{:., _, [mod_atom, func_name]}, _meta, args} = node, set
              when is_atom(mod_atom) and is_atom(func_name) and is_list(args) ->
                mod = Atom.to_string(mod_atom) |> String.replace_leading("Elixir.", "")
                {node, MapSet.put(set, {mod, to_string(func_name), length(args)})}

              # Local call: func(args) — track with module context
              {func_name, _meta, args} = node, set
              when is_atom(func_name) and is_list(args) and
                   func_name not in [:def, :defp, :defmodule, :defmacro, :defmacrop,
                                     :if, :unless, :case, :cond, :with, :for, :fn,
                                     :quote, :unquote, :import, :alias, :use, :require,
                                     :raise, :reraise, :throw, :try, :receive, :send,
                                     :spawn, :spawn_link, :super, :__block__, :__aliases__,
                                     :@, :&, :|>, :=, :==, :!=, :<, :>, :<=, :>=,
                                     :and, :or, :not, :in, :when, :{}, :%{}, :<<>>,
                                     :sigil_r, :sigil_s, :sigil_c, :sigil_w] ->
                {node, MapSet.put(set, {module_name, :local, to_string(func_name), length(args)})}

              node, set ->
                {node, set}
            end)

          calls

        _ ->
          acc
      end
    end)
  end

  # Check if a function is called with any arity (handles default arguments)
  defp called_with_any_arity?(called_functions, func) do
    mod = func.module
    name = to_string(func.name)

    Enum.any?(called_functions, fn
      {^mod, ^name, _any_arity} -> true
      {^mod, :local, ^name, _any_arity} -> true
      _ -> false
    end)
  end

  # ============================================================================
  # Fan-in / Fan-out Analysis
  # ============================================================================

  defp compute_fan_in_out(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Build module -> file lookup
    module_files =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        (data[:modules] || []) |> Enum.map(fn m -> {m.name, path} end)
      end)
      |> Map.new()

    # Get all module vertices
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)

    modules =
      module_vertices
      |> Enum.map(fn v ->
        fan_in = length(Graph.in_neighbors(graph, v))
        fan_out = length(Graph.out_neighbors(graph, v))

        %{
          module: v,
          fan_in: fan_in,
          fan_out: fan_out,
          total: fan_in + fan_out,
          file: Map.get(module_files, v, "unknown")
        }
      end)
      |> Enum.sort_by(fn m -> -(m.total) end)

    {:ok, %{modules: modules, count: length(modules)}}
  end

  # ============================================================================
  # Coupling Score (Function-level)
  # ============================================================================

  defp compute_coupling(_graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Walk all source files and collect {caller_module, callee_module, function_name} tuples
    call_pairs =
      Enum.reduce(all_asts, [], fn {path, data}, acc ->
        modules = data[:modules] || []
        caller_module = List.first(modules)[:name]

        if caller_module do
          source = case File.read(path) do
            {:ok, content} -> content
            _ -> ""
          end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              {_ast, calls} =
                Macro.prewalk(ast, acc, fn
                  # Remote call: Module.func(args)
                  {{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args} = node, list
                  when is_atom(func_name) and is_list(args) ->
                    callee = Enum.map_join(parts, ".", &to_string/1)
                    if callee != caller_module do
                      {node, [{caller_module, callee, to_string(func_name)} | list]}
                    else
                      {node, list}
                    end

                  node, list ->
                    {node, list}
                end)

              calls

            _ ->
              acc
          end
        else
          acc
        end
      end)

    # Group by {caller, callee} pair, count calls and distinct functions
    pairs =
      call_pairs
      |> Enum.group_by(fn {caller, callee, _func} -> {caller, callee} end)
      |> Enum.map(fn {{caller, callee}, calls} ->
        functions = calls |> Enum.map(fn {_, _, f} -> f end) |> Enum.uniq() |> Enum.sort()

        %{
          caller: caller,
          callee: callee,
          call_count: length(calls),
          functions: functions,
          distinct_functions: length(functions)
        }
      end)
      |> Enum.sort_by(fn p -> -p.call_count end)
      |> Enum.take(50)

    {:ok, %{pairs: pairs, count: length(pairs)}}
  end

  # ============================================================================
  # API Surface Analysis
  # ============================================================================

  defp compute_api_surface(project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    modules =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        modules = data[:modules] || []
        functions = data[:functions] || []

        case modules do
          [mod | _] ->
            public = Enum.count(functions, fn f -> f.type == :def end)
            private = Enum.count(functions, fn f -> f.type == :defp end)
            total = public + private
            ratio = if total > 0, do: Float.round(public / total, 2), else: 0.0

            [%{
              module: mod.name,
              public: public,
              private: private,
              total: total,
              ratio: ratio,
              file: path
            }]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(fn m -> -m.ratio end)

    {:ok, %{modules: modules, count: length(modules)}}
  end

  # ============================================================================
  # Change Risk Score (The Killer One)
  # ============================================================================

  defp compute_change_risk(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Pre-compute coupling map: module -> max coupling to any single other module
    coupling_map = build_coupling_map(all_asts)

    # Build module -> file lookup
    module_files =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        (data[:modules] || []) |> Enum.map(fn m -> {m.name, path} end)
      end)
      |> Map.new()

    # Get module vertices
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)

    modules =
      module_vertices
      |> Enum.map(fn mod ->
        # Fan-in / Fan-out
        fan_in = length(Graph.in_neighbors(graph, mod))
        fan_out = length(Graph.out_neighbors(graph, mod))

        # Centrality (already have)
        centrality = fan_in

        # Complexity from AST
        path = Map.get(module_files, mod)
        complexity =
          if path do
            case File.read(path) do
              {:ok, source} ->
                case Sourceror.parse_string(source) do
                  {:ok, ast} -> Giulia.AST.Processor.estimate_complexity(ast)
                  _ -> 0
                end
              _ -> 0
            end
          else
            0
          end

        # Function count + API surface
        {public, private} =
          case path do
            nil -> {0, 0}
            _ ->
              all_asts_data = Map.get(all_asts |> Map.new(), path, %{})
              functions = all_asts_data[:functions] || []
              pub = Enum.count(functions, fn f -> f.type == :def end)
              priv = Enum.count(functions, fn f -> f.type == :defp end)
              {pub, priv}
          end

        total_funcs = public + private
        api_ratio = if total_funcs > 0, do: public / total_funcs, else: 0.0

        # Max coupling to any single module
        max_coupling = Map.get(coupling_map, mod, 0)

        # ===== COMPOSITE SCORE =====
        # Centrality: high fan-in = many things break if you change this (weight: 3)
        # Complexity: hard to reason about (weight: 3)
        # Fan-out: module knows too much (weight: 2)
        # Max coupling: tightly bound to another module (weight: 2)
        # API surface: over-exposed public interface (weight: 1)
        # Function count: raw size (weight: 1)
        api_penalty = trunc(Float.round(api_ratio * total_funcs, 0))

        score =
          (centrality * 3) +
          (complexity * 3) +
          (fan_out * 2) +
          (max_coupling * 2) +
          api_penalty +
          total_funcs

        %{
          module: mod,
          score: score,
          breakdown: %{
            centrality: centrality,
            complexity: complexity,
            fan_in: fan_in,
            fan_out: fan_out,
            max_coupling: max_coupling,
            public_functions: public,
            private_functions: private,
            api_ratio: Float.round(api_ratio, 2)
          },
          file: path || "unknown"
        }
      end)
      |> Enum.sort_by(fn m -> -m.score end)
      |> Enum.take(20)

    {:ok, %{modules: modules, count: length(modules)}}
  end

  # Build a map of module -> max coupling count to any single other module
  defp build_coupling_map(all_asts) do
    # Collect all remote calls: {caller_module, callee_module}
    call_pairs =
      Enum.reduce(all_asts, [], fn {path, data}, acc ->
        modules = data[:modules] || []
        caller = List.first(modules)[:name]

        if caller do
          source = case File.read(path) do
            {:ok, content} -> content
            _ -> ""
          end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              {_ast, calls} =
                Macro.prewalk(ast, acc, fn
                  {{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args} = node, list
                  when is_atom(func_name) and is_list(args) ->
                    callee = Enum.map_join(parts, ".", &to_string/1)
                    if callee != caller do
                      {node, [{caller, callee} | list]}
                    else
                      {node, list}
                    end

                  node, list ->
                    {node, list}
                end)

              calls
            _ -> acc
          end
        else
          acc
        end
      end)

    # For each caller module, find the max call count to any single callee
    call_pairs
    |> Enum.group_by(fn {caller, _callee} -> caller end)
    |> Enum.map(fn {caller, pairs} ->
      max_to_one =
        pairs
        |> Enum.frequencies_by(fn {_caller, callee} -> callee end)
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      {caller, max_to_one}
    end)
    |> Map.new()
  end

  # ============================================================================
  # Circular Dependency Detection
  # ============================================================================

  defp compute_cycles(graph) do
    # Filter to module-only subgraph (exclude function/struct vertices)
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v ->
        labels = Graph.vertex_labels(graph, v)
        :module in labels
      end)

    # Build a module-only subgraph
    module_graph =
      Enum.reduce(module_vertices, Graph.new(type: :directed), fn v, g ->
        g = Graph.add_vertex(g, v)

        # Only add edges between modules (skip function edges)
        Graph.out_neighbors(graph, v)
        |> Enum.filter(fn neighbor -> neighbor in module_vertices end)
        |> Enum.reduce(g, fn neighbor, g2 ->
          Graph.add_edge(g2, v, neighbor)
        end)
      end)

    # Find strongly connected components with > 1 member = cycles
    cycles =
      Graph.strong_components(module_graph)
      |> Enum.filter(fn component -> length(component) > 1 end)
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort_by(fn c -> -length(c) end)

    {:ok, %{cycles: cycles, count: length(cycles)}}
  end

  # ============================================================================
  # God Module Detection
  # ============================================================================

  defp compute_god_modules(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    modules =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        modules = data[:modules] || []
        functions = data[:functions] || []

        case modules do
          [mod | _] ->
            module_name = mod.name
            func_count = length(functions)

            # Get complexity from AST
            complexity =
              case File.read(path) do
                {:ok, source} ->
                  case Sourceror.parse_string(source) do
                    {:ok, ast} -> Giulia.AST.Processor.estimate_complexity(ast)
                    _ -> 0
                  end
                _ -> 0
              end

            # Get centrality from graph
            centrality =
              case compute_centrality(graph, module_name) do
                {:ok, %{in_degree: in_deg}} -> in_deg
                _ -> 0
              end

            # God module score: weighted combination
            # Functions weight: 1x, Complexity weight: 2x, Centrality weight: 3x
            score = func_count + (complexity * 2) + (centrality * 3)

            [%{
              module: module_name,
              functions: func_count,
              complexity: complexity,
              centrality: centrality,
              score: score,
              file: path
            }]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(fn m -> -m.score end)
      |> Enum.take(20)

    {:ok, %{modules: modules, count: length(modules)}}
  end

  # ============================================================================
  # Orphan Spec Detection
  # ============================================================================

  defp compute_orphan_specs(project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    orphans =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        specs = data[:specs] || []
        functions = data[:functions] || []
        modules = data[:modules] || []
        module_name = List.first(modules)[:name] || "Unknown"

        # Build set of defined {function_name, arity} pairs
        defined_funcs =
          functions
          |> Enum.map(fn f -> {f.name, f.arity} end)
          |> MapSet.new()

        # Find specs that don't match any defined function
        Enum.reject(specs, fn spec ->
          MapSet.member?(defined_funcs, {spec.function, spec.arity})
        end)
        |> Enum.map(fn spec ->
          %{
            module: module_name,
            spec_function: to_string(spec.function),
            spec_arity: spec.arity,
            line: spec.line,
            file: path
          }
        end)
      end)
      |> Enum.sort_by(&{&1.module, &1.spec_function, &1.spec_arity})

    {:ok, %{orphans: orphans, count: length(orphans)}}
  end

  defp compute_stats(graph) do
    vertices = Graph.vertices(graph)
    vertex_count = length(vertices)
    edge_count = Graph.num_edges(graph)
    components = Graph.components(graph) |> length()

    # Count by type
    type_counts =
      vertices
      |> Enum.reduce(%{modules: 0, functions: 0, structs: 0, behaviours: 0}, fn v, acc ->
        labels = Graph.vertex_labels(graph, v)
        cond do
          :module in labels -> %{acc | modules: acc.modules + 1}
          :function in labels -> %{acc | functions: acc.functions + 1}
          :struct in labels -> %{acc | structs: acc.structs + 1}
          :behaviour in labels -> %{acc | behaviours: acc.behaviours + 1}
          true -> acc
        end
      end)

    # Find hub modules (most connections)
    hubs =
      vertices
      |> Enum.filter(fn v -> Graph.vertex_labels(graph, v) == [:module] end)
      |> Enum.map(fn v ->
        in_degree = length(Graph.in_neighbors(graph, v))
        out_degree = length(Graph.out_neighbors(graph, v))
        {v, in_degree + out_degree}
      end)
      |> Enum.sort_by(fn {_v, degree} -> -degree end)
      |> Enum.take(5)

    %{
      vertices: vertex_count,
      edges: edge_count,
      components: components,
      type_counts: type_counts,
      hubs: hubs
    }
  end
end
