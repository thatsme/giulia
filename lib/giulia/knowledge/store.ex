defmodule Giulia.Knowledge.Store do
  @moduledoc """
  Knowledge Graph — Project Topology as a Directed Graph.

  Upgrades Giulia from a flat index (ETS lists of modules/functions) to a
  deterministic graph of relationships: who depends on whom, what calls what,
  what's the blast radius of a change.

  Uses libgraph (pure Elixir, no NIFs) for graph operations.

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
  Rebuild the entire knowledge graph from Context.Store AST data.
  Called automatically after indexing completes.
  """
  def rebuild do
    GenServer.cast(__MODULE__, :rebuild)
  end

  @doc """
  Rebuild with a specific set of AST data (for testing).
  """
  def rebuild(ast_data) when is_map(ast_data) do
    GenServer.call(__MODULE__, {:rebuild, ast_data}, 30_000)
  end

  @doc """
  Get impact map for a module — who depends on it and what it depends on.
  """
  def impact_map(vertex_id, depth \\ 2) do
    GenServer.call(__MODULE__, {:impact_map, vertex_id, depth})
  end

  @doc """
  Trace the shortest path between two vertices.
  """
  def trace_path(from, to) do
    GenServer.call(__MODULE__, {:trace_path, from, to})
  end

  @doc """
  Get modules that depend on the given module (downstream).
  """
  def dependents(module) do
    GenServer.call(__MODULE__, {:dependents, module})
  end

  @doc """
  Get modules that the given module depends on (upstream).
  """
  def dependencies(module) do
    GenServer.call(__MODULE__, {:dependencies, module})
  end

  @doc """
  Get the degree centrality of a module — count of direct dependents (in-degree).
  Returns {:ok, %{in_degree: N, out_degree: N, dependents: [names]}} or {:error, :not_found}.
  Used by the Orchestrator's Hub Alarm to assess risk before approving edits.
  """
  def centrality(module) do
    GenServer.call(__MODULE__, {:centrality, module})
  end

  @doc """
  Get test targets for a module — its own test file plus tests for direct dependents.
  Used by the Orchestrator's auto-regression to run only the tests that matter.
  Returns {:ok, %{direct: path, dependents: [{module, path}], all_paths: [paths]}}
  """
  def get_test_targets(module, project_path) do
    GenServer.call(__MODULE__, {:test_targets, module, project_path})
  end

  @doc """
  Check behaviour-implementer consistency for a specific behaviour module.
  Returns {:ok, :consistent} or {:error, fractures}.
  """
  def check_behaviour_integrity(behaviour_module) do
    GenServer.call(__MODULE__, {:check_behaviour_integrity, behaviour_module})
  end

  @doc """
  Check all behaviours in the project for implementer consistency.
  Returns {:ok, :consistent} or {:error, %{behaviour => [fracture]}}.
  """
  def check_all_behaviours do
    GenServer.call(__MODULE__, :check_all_behaviours, 30_000)
  end

  @doc """
  Get graph statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get the raw graph (for debugging).
  """
  def graph do
    GenServer.call(__MODULE__, :graph)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{graph: Graph.new(type: :directed)}}
  end

  @impl true
  def handle_cast(:rebuild, state) do
    ast_data = Giulia.Context.Store.all_asts()
    graph = build_graph(ast_data)

    vertex_count = Graph.num_vertices(graph)
    edge_count = Graph.num_edges(graph)
    Logger.info("Knowledge graph rebuilt: #{vertex_count} vertices, #{edge_count} edges")

    {:noreply, %{state | graph: graph}}
  end

  @impl true
  def handle_call({:rebuild, ast_data}, _from, state) do
    graph = build_graph(ast_data)
    {:reply, :ok, %{state | graph: graph}}
  end

  @impl true
  def handle_call({:impact_map, vertex_id, depth}, _from, %{graph: graph} = state) do
    result = compute_impact_map(graph, vertex_id, depth)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:trace_path, from, to}, _from, %{graph: graph} = state) do
    result = compute_trace_path(graph, from, to)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependents, module}, _from, %{graph: graph} = state) do
    result = compute_dependents(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:dependencies, module}, _from, %{graph: graph} = state) do
    result = compute_dependencies(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:centrality, module}, _from, %{graph: graph} = state) do
    result = compute_centrality(graph, module)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:test_targets, module, project_path}, _from, %{graph: graph} = state) do
    result = compute_test_targets(graph, module, project_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_behaviour_integrity, behaviour}, _from, %{graph: graph} = state) do
    result = compute_behaviour_integrity(graph, behaviour)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:check_all_behaviours, _from, %{graph: graph} = state) do
    result = compute_all_behaviours(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, %{graph: graph} = state) do
    result = compute_stats(graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:graph, _from, %{graph: graph} = state) do
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
    case Giulia.Context.Store.find_module(module_name) do
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

  defp compute_behaviour_integrity(graph, behaviour) do
    if not Graph.has_vertex?(graph, behaviour) do
      {:error, :not_found}
    else
      # Get declared callbacks from ETS
      callbacks = Giulia.Context.Store.list_callbacks(behaviour)

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
              Giulia.Context.Store.list_functions(impl_mod)
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

  defp compute_all_behaviours(graph) do
    # Find behaviour modules from ETS (modules that declare @callback).
    # We can't rely on :behaviour vertex labels because libgraph's add_vertex
    # is a no-op when the vertex already exists — so :module always wins.
    behaviour_modules =
      Giulia.Context.Store.list_callbacks()
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.filter(&Graph.has_vertex?(graph, &1))

    # Check each behaviour
    all_fractures =
      Enum.reduce(behaviour_modules, %{}, fn behaviour, acc ->
        case compute_behaviour_integrity(graph, behaviour) do
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
