defmodule Giulia.Knowledge.Analyzer do
  @moduledoc """
  Pure analytical functions for the Knowledge Graph.

  All functions are stateless — they take a `%Graph{}` (and/or `project_path`)
  and return computed metrics. No GenServer, no state mutation.

  Extracted from `Knowledge.Store` (Build 81) to separate the Librarian
  (GenServer + state management) from the Data Scientist (graph analytics).
  """

  require Logger

  alias Giulia.Knowledge.MacroMap

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

  # ============================================================================
  # Graph Statistics
  # ============================================================================

  def stats(graph) do
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

  # ============================================================================
  # Centrality & Neighbors
  # ============================================================================

  def centrality(graph, module) do
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

  def dependents(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # Who points TO this module (incoming edges) = who depends on me
      deps = Graph.in_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  def dependencies(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # What this module points TO (outgoing edges) = what I depend on
      deps = Graph.out_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  # ============================================================================
  # Impact Analysis
  # ============================================================================

  def impact_map(graph, vertex_id, depth) do
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

  def trace_path(graph, from, to) do
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

  # --- Impact helpers (private) ---

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

  # Simple fuzzy scoring: substring match + bonus for matching final segment
  defp fuzzy_score(haystack, needle) do
    cond do
      haystack == needle -> 100
      String.contains?(haystack, needle) -> 50
      last_segment_match?(haystack, needle) -> 30
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

  # ============================================================================
  # Test Targets
  # ============================================================================

  def test_targets(graph, module, project_path) do
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
    case Giulia.Context.Store.find_module(project_path, module_name) do
      {:ok, %{file: source_file}} ->
        test_file = Giulia.Tools.RunTests.suggest_test_file(source_file)
        full_path = Path.join(project_path, test_file)
        if File.exists?(full_path), do: test_file, else: nil
      _ ->
        nil
    end
  end

  # ============================================================================
  # Behaviour Integrity Check
  # ============================================================================

  def behaviour_integrity(graph, behaviour, project_path) do
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

        # Split optional vs required callbacks
        optional_set =
          callbacks
          |> Enum.filter(fn cb -> Map.get(cb, :optional, false) == true end)
          |> Enum.map(fn cb -> {to_string(cb.function), cb.arity} end)
          |> MapSet.new()

        required_set = MapSet.difference(callback_set, optional_set)

        # Get implementers: modules with :implements edge pointing TO this behaviour
        implementers =
          Graph.in_edges(graph, behaviour)
          |> Enum.filter(fn edge -> edge.label == :implements end)
          |> Enum.map(fn edge -> edge.v1 end)
          |> Enum.uniq()

        # Check each implementer
        fractures =
          Enum.map(implementers, fn impl_mod ->
            # Get public functions of the implementer
            impl_functions =
              Giulia.Context.Store.list_functions(project_path, impl_mod)
              |> Enum.filter(fn f -> f.type == :def end)
              |> Enum.map(fn f -> {to_string(f.name), f.arity} end)
              |> MapSet.new()

            # Get use directives for this implementer and compute macro-injected functions
            use_directives = get_use_directives(project_path, impl_mod)
            macro_injected =
              use_directives
              |> Enum.flat_map(&MacroMap.injected_functions/1)
              |> MapSet.new()

            # Union: explicitly defined + macro-injected
            all_provided = MapSet.union(impl_functions, macro_injected)

            # Find required callbacks truly missing (not defined AND not injected)
            truly_missing =
              required_set
              |> MapSet.difference(all_provided)
              |> MapSet.to_list()

            # Track which callbacks are covered by macros (for enriched output)
            macro_covered =
              callback_set
              |> MapSet.difference(impl_functions)
              |> MapSet.intersection(macro_injected)
              |> MapSet.to_list()

            # Track optional callbacks that are omitted (legal, not fractures)
            optional_missing =
              optional_set
              |> MapSet.difference(all_provided)
              |> MapSet.to_list()

            %{
              implementer: impl_mod,
              missing: truly_missing,
              injected: macro_covered,
              optional_omitted: optional_missing,
              heuristic_injected: []
            }
          end)

        # Post-processing: detect macro ghosts (100% miss heuristic)
        fractures = detect_macro_ghosts(fractures, implementers, project_path)

        # Only report fractures where required callbacks are genuinely missing
        real_fractures = Enum.filter(fractures, fn f -> f.missing != [] end)

        if real_fractures == [] do
          {:ok, :consistent}
        else
          {:error, real_fractures}
        end
      end
    end
  end

  # Heuristic: if a callback is "missing" from 100% of implementers,
  # AND all those implementers `use` the behaviour module (or a shared module),
  # it's likely injected by a macro. Reclassify from missing → heuristic_injected.
  defp detect_macro_ghosts(fractures, implementers, project_path) when length(implementers) >= 2 do
    # Group all missing callbacks across implementers
    all_missing =
      fractures
      |> Enum.flat_map(fn f -> Enum.map(f.missing, fn cb -> {cb, f.implementer} end) end)
      |> Enum.group_by(fn {cb, _impl} -> cb end, fn {_cb, impl} -> impl end)

    impl_count = length(implementers)

    # Callbacks missing from ALL implementers = ghost candidates
    ghost_candidates =
      all_missing
      |> Enum.filter(fn {_cb, impls} -> length(Enum.uniq(impls)) == impl_count end)
      |> Enum.map(fn {cb, _impls} -> cb end)
      |> MapSet.new()

    if MapSet.size(ghost_candidates) == 0 do
      fractures
    else
      # Verify all implementers share a common `use` directive
      use_sets =
        Enum.map(implementers, fn impl ->
          get_use_directives(project_path, impl) |> MapSet.new()
        end)

      common_uses =
        case use_sets do
          [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
          [] -> MapSet.new()
        end

      if MapSet.size(common_uses) > 0 do
        # Reclassify ghost candidates
        Enum.map(fractures, fn f ->
          {ghosts, real_missing} =
            Enum.split_with(f.missing, fn cb -> MapSet.member?(ghost_candidates, cb) end)

          %{f | missing: real_missing, heuristic_injected: f.heuristic_injected ++ ghosts}
        end)
      else
        fractures
      end
    end
  end

  defp detect_macro_ghosts(fractures, _implementers, _project_path), do: fractures

  # Get use directives for a module from ETS
  defp get_use_directives(project_path, module_name) do
    case Giulia.Context.Store.find_module(project_path, module_name) do
      {:ok, %{ast_data: ast_data}} ->
        (ast_data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :use end)
        |> Enum.map(fn imp -> imp.module end)

      _ ->
        []
    end
  end

  def all_behaviours(graph, project_path) do
    # Find behaviour modules from ETS (modules that declare @callback).
    behaviour_modules =
      Giulia.Context.Store.list_callbacks(project_path)
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.filter(&Graph.has_vertex?(graph, &1))

    # Check each behaviour
    all_fractures =
      Enum.reduce(behaviour_modules, %{}, fn behaviour, acc ->
        case behaviour_integrity(graph, behaviour, project_path) do
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

  def dead_code(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    dead_code_with_asts(graph, project_path, all_asts)
  end

  # --- Dead code helpers (private) ---

  # For each module that implements a behaviour, collect the behaviour's callbacks
  # as {implementer_module, callback_name, callback_arity} — these are called implicitly
  defp collect_behaviour_callbacks(graph, project_path) do
    Graph.edges(graph)
    |> Enum.filter(fn edge -> edge.label == :implements end)
    |> Enum.reduce(MapSet.new(), fn edge, acc ->
      implementer = edge.v1
      behaviour = edge.v2

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

      # Build alias map: "Schema" → "Realm.Compute.Schema"
      alias_map =
        (data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :alias end)
        |> Map.new(fn imp ->
          short = imp.module |> String.split(".") |> List.last()
          {short, imp.module}
        end)

      # Read source from disk — ETS stores metadata, not raw source
      source = case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end

      case Sourceror.parse_string(source) do
        {:ok, ast} ->
          {_ast, calls} =
            Macro.prewalk(ast, acc, fn
              # Remote call: Module.func(args) — resolve aliases
              {{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args} = node, set
              when is_atom(func_name) and is_list(args) ->
                raw_mod = Enum.map_join(parts, ".", &to_string/1)
                mod = Map.get(alias_map, raw_mod, raw_mod)
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

  def fan_in_out(graph, project_path) do
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

  def coupling(project_path) do
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

  # Build a map of module -> max coupling count to any single other module
  defp build_coupling_map(all_asts) do
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
  # API Surface Analysis
  # ============================================================================

  def api_surface(project_path) do
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
  # Change Risk Score
  # ============================================================================

  def change_risk(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    coupling_map = build_coupling_map(all_asts)
    change_risk_with_coupling(graph, project_path, all_asts, coupling_map)
  end

  @doc false
  def change_risk_with_coupling(graph, _project_path, all_asts, coupling_map) do
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
        centrality_val = fan_in

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
        api_penalty = trunc(Float.round(api_ratio * total_funcs, 0))

        base =
          (complexity * 2) +
          (fan_out * 2) +
          (max_coupling * 2) +
          api_penalty +
          total_funcs

        multiplier = 1 + (centrality_val / 2)

        score = trunc(base * multiplier)

        %{
          module: mod,
          score: score,
          breakdown: %{
            centrality: centrality_val,
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

  # ============================================================================
  # Circular Dependency Detection
  # ============================================================================

  def cycles(graph) do
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

  def god_modules(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    god_modules_impl(graph, project_path, all_asts)
  end

  @doc false
  def god_modules_impl(graph, _project_path, all_asts) do
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
            centrality_val =
              case centrality(graph, module_name) do
                {:ok, %{in_degree: in_deg}} -> in_deg
                _ -> 0
              end

            # God module score: weighted combination
            score = func_count + (complexity * 2) + (centrality_val * 3)

            [%{
              module: module_name,
              functions: func_count,
              complexity: complexity,
              centrality: centrality_val,
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

  def orphan_specs(project_path) do
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

  # ============================================================================
  # Logic Flow (Function-level Dijkstra path)
  # ============================================================================

  def logic_flow(graph, project_path, from_mfa, to_mfa) do
    cond do
      not Graph.has_vertex?(graph, from_mfa) ->
        {:error, {:not_found, from_mfa}}

      not Graph.has_vertex?(graph, to_mfa) ->
        {:error, {:not_found, to_mfa}}

      true ->
        case Graph.dijkstra(graph, from_mfa, to_mfa) do
          nil ->
            {:ok, :no_path}

          path ->
            steps = Enum.map(path, fn mfa -> enrich_mfa_vertex(mfa, project_path) end)
            {:ok, steps}
        end
    end
  end

  defp enrich_mfa_vertex(mfa, project_path) do
    case parse_mfa_vertex(mfa) do
      {:ok, module, function, arity} ->
        # Look up file and line from ETS
        {file, line} =
          case Giulia.Context.Store.find_module(project_path, module) do
            {:ok, %{file: file, ast_data: ast_data}} ->
              func_line =
                (ast_data[:functions] || [])
                |> Enum.find(fn f ->
                  to_string(f.name) == function and f.arity == arity
                end)
                |> case do
                  nil -> nil
                  f -> f.line
                end
              {file, func_line}
            _ ->
              {nil, nil}
          end

        %{mfa: mfa, module: module, function: function, arity: arity, file: file, line: line}

      :error ->
        %{mfa: mfa, module: mfa, function: nil, arity: nil, file: nil, line: nil}
    end
  end

  # Parse "Giulia.Foo.bar/2" into {:ok, "Giulia.Foo", "bar", 2}
  defp parse_mfa_vertex(mfa) do
    case Regex.run(~r/^(.+)\.([^.]+)\/(\d+)$/, mfa) do
      [_, module, function, arity_str] ->
        {:ok, module, function, String.to_integer(arity_str)}
      _ ->
        :error
    end
  end

  # ============================================================================
  # Style Oracle (Semantic search + quality gate)
  # ============================================================================

  def style_oracle(project_path, query, top_k) do
    # Broad semantic search (3x top_k for filtering headroom)
    case Giulia.Intelligence.SemanticIndex.search(project_path, query, top_k * 3) do
      {:ok, %{functions: function_results}} ->
        # Quality gate: only functions with BOTH @spec AND @doc
        exemplars =
          function_results
          |> Enum.map(fn result ->
            module = result.metadata.module
            function = result.metadata.function
            arity = result.metadata.arity
            file = result.metadata.file
            line = result.metadata.line

            spec = case Giulia.Context.Store.get_spec(project_path, module, function, arity) do
              %{spec: s} when is_binary(s) and s != "" -> s
              _ -> nil
            end

            doc = case Giulia.Context.Store.get_function_doc(project_path, module, function, arity) do
              %{doc: d} when is_binary(d) and d != "" -> d
              _ -> nil
            end

            # Try to get source code
            source = if file do
              func_atom = String.to_atom(function)
              case File.read(file) do
                {:ok, content} ->
                  case Giulia.AST.Processor.slice_function(content, func_atom, arity) do
                    {:ok, src} -> src
                    _ -> nil
                  end
                _ -> nil
              end
            end

            %{
              mfa: "#{module}.#{function}/#{arity}",
              score: result.score,
              spec: spec,
              doc: doc,
              source: source,
              file: file,
              line: line,
              has_spec: spec != nil,
              has_doc: doc != nil
            }
          end)
          |> Enum.filter(fn e -> e.has_spec and e.has_doc end)
          |> Enum.take(top_k)
          |> Enum.map(fn e -> Map.drop(e, [:has_spec, :has_doc]) end)

        {:ok, %{
          query: query,
          exemplars: exemplars,
          count: length(exemplars),
          quality_gate: "Functions with both @spec and @doc"
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Pre-Impact Check (Rename/Remove risk analysis)
  # ============================================================================

  def pre_impact_check(graph, project_path, params) do
    action = params["action"]
    module = params["module"]
    target = params["target"]
    new_name = params["new_name"]

    case action do
      "rename_function" ->
        check_rename_function(graph, project_path, module, target, new_name)

      "remove_function" ->
        check_remove_function(graph, project_path, module, target)

      "rename_module" ->
        check_rename_module(graph, project_path, module, new_name)

      _ ->
        {:error, {:unknown_action, action}}
    end
  end

  defp check_rename_function(graph, project_path, module, target, new_name) do
    case parse_func_target(target) do
      {:ok, func_name, arity} ->
        mfa = "#{module}.#{func_name}/#{arity}"

        if not Graph.has_vertex?(graph, mfa) do
          {:error, {:not_found, mfa}}
        else
          # Find all callers (in-neighbors on MFA vertex)
          callers = Graph.in_neighbors(graph, mfa)
                    |> Enum.filter(fn v -> String.contains?(v, "/") end)

          affected = Enum.map(callers, fn caller_mfa ->
            enrich_mfa_vertex(caller_mfa, project_path)
          end)

          affected_modules =
            affected
            |> Enum.map(& &1.module)
            |> Enum.uniq()

          new_mfa = "#{module}.#{new_name}/#{arity}"

          risk = impact_risk(length(callers), length(affected_modules), graph, affected_modules)
          phases = build_phases(module, affected, graph)

          warnings = build_hub_warnings(graph, affected_modules)

          {:ok, %{
            action: "rename_function",
            target: mfa,
            new_name: new_mfa,
            affected_callers: affected,
            affected_count: length(affected),
            affected_modules: length(affected_modules),
            risk_score: risk,
            risk_level: risk_level(risk),
            phases: phases,
            warnings: warnings
          }}
        end

      :error ->
        {:error, {:invalid_target, target}}
    end
  end

  defp check_remove_function(graph, project_path, module, target) do
    case parse_func_target(target) do
      {:ok, func_name, arity} ->
        mfa = "#{module}.#{func_name}/#{arity}"

        if not Graph.has_vertex?(graph, mfa) do
          {:error, {:not_found, mfa}}
        else
          callers = Graph.in_neighbors(graph, mfa)
                    |> Enum.filter(fn v -> String.contains?(v, "/") end)

          callees = Graph.out_neighbors(graph, mfa)
                    |> Enum.filter(fn v -> String.contains?(v, "/") end)

          affected = Enum.map(callers, fn caller_mfa ->
            enrich_mfa_vertex(caller_mfa, project_path)
          end)

          affected_modules =
            affected
            |> Enum.map(& &1.module)
            |> Enum.uniq()

          risk = impact_risk(length(callers), length(affected_modules), graph, affected_modules)
          phases = build_phases(module, affected, graph)

          warnings =
            build_hub_warnings(graph, affected_modules) ++
            if length(callers) > 0 do
              ["BREAKING: #{length(callers)} callers will break if #{mfa} is removed"]
            else
              []
            end

          # Find orphaned callees (things only called by this function)
          orphaned = Enum.filter(callees, fn callee ->
            callers_of_callee = Graph.in_neighbors(graph, callee)
            callers_of_callee == [mfa] or callers_of_callee == []
          end)

          {:ok, %{
            action: "remove_function",
            target: mfa,
            affected_callers: affected,
            affected_count: length(affected),
            affected_modules: length(affected_modules),
            potentially_orphaned: orphaned,
            risk_score: risk,
            risk_level: risk_level(risk),
            phases: phases,
            warnings: warnings
          }}
        end

      :error ->
        {:error, {:invalid_target, target}}
    end
  end

  defp check_rename_module(graph, project_path, module, new_name) do
    if not Graph.has_vertex?(graph, module) do
      {:error, {:not_found, module}}
    else
      case dependents(graph, module) do
        {:ok, deps} ->
          # Hub penalty
          hub_penalty = case centrality(graph, module) do
            {:ok, %{in_degree: in_deg}} when in_deg >= 10 -> in_deg * 3
            {:ok, %{in_degree: in_deg}} -> in_deg
            _ -> 0
          end

          affected = Enum.map(deps, fn dep ->
            case Giulia.Context.Store.find_module(project_path, dep) do
              {:ok, %{file: file}} -> %{module: dep, file: file}
              _ -> %{module: dep, file: nil}
            end
          end)

          risk = length(deps) * 5 + hub_penalty
          warnings = if hub_penalty > 30, do: ["HUB MODULE: #{module} has #{hub_penalty} hub penalty"], else: []

          {:ok, %{
            action: "rename_module",
            target: module,
            new_name: new_name,
            affected_dependents: affected,
            affected_count: length(affected),
            risk_score: risk,
            risk_level: risk_level(risk),
            warnings: warnings
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Phase algorithm: target first, then leaf callers, then interconnected
  defp build_phases(target_module, affected_callers, graph) do
    phase1 = %{phase: 1, description: "Update target definition", modules: [target_module]}

    # Group callers by module
    caller_modules =
      affected_callers
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.reject(& &1 == target_module)

    affected_set = MapSet.new(caller_modules)

    # Leaf callers: no deps on other affected modules
    {leaves, interconnected} =
      Enum.split_with(caller_modules, fn mod ->
        deps = case Graph.out_neighbors(graph, mod) do
          neighbors when is_list(neighbors) -> neighbors
          _ -> []
        end

        not Enum.any?(deps, fn dep -> MapSet.member?(affected_set, dep) and dep != mod end)
      end)

    phases = [phase1]
    phases = if leaves != [], do: phases ++ [%{phase: 2, description: "Update leaf callers", modules: Enum.sort(leaves)}], else: phases
    phases = if interconnected != [], do: phases ++ [%{phase: 3, description: "Update interconnected callers", modules: Enum.sort(interconnected)}], else: phases
    phases
  end

  defp impact_risk(caller_count, module_count, graph, affected_modules) do
    hub_penalty =
      Enum.sum(Enum.map(affected_modules, fn mod ->
        case centrality(graph, mod) do
          {:ok, %{in_degree: in_deg}} when in_deg >= 10 -> 10
          _ -> 0
        end
      end))

    caller_count * 2 + module_count * 5 + hub_penalty
  end

  defp risk_level(score) when score < 20, do: "low"
  defp risk_level(score) when score < 50, do: "medium"
  defp risk_level(_score), do: "high"

  defp build_hub_warnings(graph, affected_modules) do
    Enum.flat_map(affected_modules, fn mod ->
      case centrality(graph, mod) do
        {:ok, %{in_degree: in_deg}} when in_deg >= 10 ->
          ["HUB CALLER: #{mod} has #{in_deg} dependents"]
        _ ->
          []
      end
    end)
  end

  # Parse "func/arity" or "func_name/2" into {:ok, "func", 2}
  defp parse_func_target(target) do
    case Regex.run(~r/^(.+)\/(\d+)$/, target) do
      [_, func, arity_str] -> {:ok, func, String.to_integer(arity_str)}
      _ -> :error
    end
  end

  # ============================================================================
  # Heatmap (Composite module health score)
  # ============================================================================

  def heatmap(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    coupling_map = build_coupling_map(all_asts)
    heatmap_with_coupling(graph, project_path, all_asts, coupling_map)
  end

  @doc false
  def heatmap_with_coupling(graph, project_path, all_asts, coupling_map) do
    # Module -> file lookup
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

    # Compute per-module scores
    modules =
      module_vertices
      |> Enum.map(fn mod ->
        path = Map.get(module_files, mod)

        # Factor 1: Centrality (in-degree)
        centrality_val = length(Graph.in_neighbors(graph, mod))

        # Factor 2: Complexity
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

        # Factor 3: Test fragility (does a test file exist?)
        has_test =
          if path do
            test_file = Giulia.Tools.RunTests.suggest_test_file(path)
            full_test = Path.join(project_path, test_file)
            File.exists?(full_test)
          else
            false
          end

        # Factor 4: Max coupling
        max_coupling = Map.get(coupling_map, mod, 0)

        # Normalize each factor to 0-100
        norm_centrality = min(centrality_val / 15 * 100, 100) |> trunc()
        norm_complexity = min(complexity / 200 * 100, 100) |> trunc()
        norm_test = if has_test, do: 0, else: 100
        norm_coupling = min(max_coupling / 50 * 100, 100) |> trunc()

        # Weighted composite
        score =
          trunc(
            norm_centrality * 0.30 +
            norm_complexity * 0.25 +
            norm_test * 0.25 +
            norm_coupling * 0.20
          )

        zone = cond do
          score >= 60 -> "red"
          score >= 30 -> "yellow"
          true -> "green"
        end

        %{
          module: mod,
          score: score,
          zone: zone,
          breakdown: %{
            complexity: complexity,
            centrality: centrality_val,
            max_coupling: max_coupling,
            has_test: has_test
          },
          file: path || "unknown"
        }
      end)
      |> Enum.sort_by(fn m -> -m.score end)

    zones = Enum.frequencies_by(modules, & &1.zone)

    {:ok, %{
      modules: modules,
      count: length(modules),
      zones: %{
        red: Map.get(zones, "red", 0),
        yellow: Map.get(zones, "yellow", 0),
        green: Map.get(zones, "green", 0)
      }
    }}
  end

  # ============================================================================
  # Unprotected Hub Detection (Feature 1: Build 89)
  # ============================================================================

  @doc """
  Find hub modules with insufficient spec/doc coverage.

  Merges graph centrality with ETS spec/doc data to identify dangerous gaps:
  modules that many others depend on but lack type safety or documentation.

  Severity: red (spec_ratio < 0.5), yellow (spec_ratio < 0.8).
  """
  @spec find_unprotected_hubs(Graph.t(), String.t(), keyword()) ::
          {:ok, %{modules: [map()], count: non_neg_integer(), severity_counts: map()}}
  def find_unprotected_hubs(graph, project_path, opts \\ []) do
    hub_threshold = Keyword.get(opts, :hub_threshold, 3)
    spec_threshold = Keyword.get(opts, :spec_threshold, 0.5)

    # Get module vertices with sufficient in-degree
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)

    hubs =
      module_vertices
      |> Enum.map(fn mod ->
        in_degree = length(Graph.in_neighbors(graph, mod))
        {mod, in_degree}
      end)
      |> Enum.filter(fn {_mod, in_deg} -> in_deg >= hub_threshold end)
      |> Enum.map(fn {mod, in_degree} ->
        # Query ETS for spec/doc/function coverage
        public_functions =
          Giulia.Context.Store.list_functions(project_path, mod)
          |> Enum.filter(fn f -> f.type == :def end)

        specs = Giulia.Context.Store.list_specs(project_path, mod)
        docs = Giulia.Context.Store.list_docs(project_path, mod)

        public_count = length(public_functions)
        spec_count = length(specs)
        doc_count = length(docs)

        spec_ratio = if public_count > 0, do: Float.round(spec_count / public_count, 2), else: 1.0
        doc_ratio = if public_count > 0, do: Float.round(doc_count / public_count, 2), else: 1.0

        # Check test file existence
        has_test =
          case Giulia.Context.Store.find_module(project_path, mod) do
            {:ok, %{file: file}} ->
              test_file = Giulia.Tools.RunTests.suggest_test_file(file)
              full_path = Path.join(project_path, test_file)
              File.exists?(full_path)

            _ ->
              false
          end

        # Severity classification
        severity = cond do
          spec_ratio < spec_threshold -> "red"
          spec_ratio < 0.8 -> "yellow"
          true -> "green"
        end

        %{
          module: mod,
          in_degree: in_degree,
          public_functions: public_count,
          spec_count: spec_count,
          doc_count: doc_count,
          spec_ratio: spec_ratio,
          doc_ratio: doc_ratio,
          has_test: has_test,
          severity: severity
        }
      end)
      |> Enum.reject(fn h -> h.severity == "green" end)
      |> Enum.sort_by(fn h ->
        severity_order = if h.severity == "red", do: 0, else: 1
        {severity_order, -h.in_degree}
      end)

    severity_counts = Enum.frequencies_by(hubs, & &1.severity)

    {:ok, %{
      modules: hubs,
      count: length(hubs),
      severity_counts: %{
        red: Map.get(severity_counts, "red", 0),
        yellow: Map.get(severity_counts, "yellow", 0)
      }
    }}
  end

  # ============================================================================
  # Struct Lifecycle Tracing (Feature 2: Build 89)
  # ============================================================================

  @doc """
  Map struct data flow across modules: who creates, who consumes, logic leaks.

  Walks all source files looking for `%ModuleName{}` patterns in AST to find
  struct construction and pattern matching. Logic leaks are modules that both
  create AND consume a struct but are NOT the defining module.

  v1 limitations: cannot distinguish construction from pattern match (same AST
  shape), cannot track struct update syntax or field access without type inference.
  """
  @spec struct_lifecycle(String.t(), String.t() | nil) ::
          {:ok, %{structs: [map()], count: non_neg_integer()}}
  def struct_lifecycle(project_path, struct_filter \\ nil) do
    # Get all defined structs
    all_structs = Giulia.Context.Store.list_structs(project_path)

    # Optionally filter to a single struct
    target_structs =
      if struct_filter do
        Enum.filter(all_structs, fn s -> s.module == struct_filter end)
      else
        all_structs
      end

    struct_names = Enum.map(target_structs, & &1.module) |> MapSet.new()

    # Walk all source files to find struct usage
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Build alias maps and collect struct references per file
    usage_data =
      Enum.reduce(all_asts, %{}, fn {path, data}, acc ->
        modules = data[:modules] || []
        file_module = case modules do
          [first | _] -> first.name
          _ -> nil
        end

        if is_nil(file_module) do
          acc
        else
          source = case File.read(path) do
            {:ok, content} -> content
            _ -> ""
          end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              # Build alias map for resolving short names
              alias_map =
                (data[:imports] || [])
                |> Enum.filter(fn imp -> imp.type == :alias end)
                |> Map.new(fn imp ->
                  short = imp.module |> String.split(".") |> List.last()
                  {short, imp.module}
                end)

              # Walk AST looking for struct patterns: %ModuleName{...}
              {_ast, refs} =
                Macro.prewalk(ast, [], fn
                  # %Module.Name{...} — struct construction or pattern match
                  {:%, _meta, [{:__aliases__, _, parts}, {:%{}, _, _}]} = node, refs ->
                    raw_name = Enum.map_join(parts, ".", &to_string/1)
                    resolved = Map.get(alias_map, raw_name, raw_name)
                    if MapSet.member?(struct_names, resolved) do
                      {node, [{resolved, file_module} | refs]}
                    else
                      {node, refs}
                    end

                  node, refs ->
                    {node, refs}
                end)

              Enum.reduce(refs, acc, fn {struct_mod, using_mod}, map ->
                existing = Map.get(map, struct_mod, MapSet.new())
                Map.put(map, struct_mod, MapSet.put(existing, using_mod))
              end)

            _ ->
              acc
          end
        end
      end)

    # Build lifecycle per struct
    structs =
      target_structs
      |> Enum.map(fn struct_info ->
        defining_mod = struct_info.module
        users = Map.get(usage_data, defining_mod, MapSet.new()) |> MapSet.to_list()

        # Creators = modules that reference the struct (v1: can't distinguish create vs pattern match)
        # Consumers = same set (v1 limitation)
        # Logic leaks = non-defining modules that appear in users
        logic_leaks = Enum.reject(users, fn mod -> mod == defining_mod end)

        %{
          struct: defining_mod,
          fields: struct_info.fields,
          defining_module: defining_mod,
          users: Enum.sort(users),
          user_count: length(users),
          logic_leaks: Enum.sort(logic_leaks),
          leak_count: length(logic_leaks)
        }
      end)
      |> Enum.sort_by(fn s -> -s.leak_count end)

    {:ok, %{structs: structs, count: length(structs)}}
  end

  # ============================================================================
  # Cached Metric Computation (Build 97, expanded Build 99)
  # ============================================================================

  @doc """
  Compute all heavy metrics in one pass: heatmap, change_risk, god_modules,
  dead_code, and coupling.

  Single Sourceror pass via `collect_remote_calls/1` feeds both coupling and
  coupling_map (was two separate parses before Build 99). Called by
  Knowledge.Store in a background Task after graph rebuild, results cached
  for <10ms reads.
  """
  def compute_cached_metrics(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Single Sourceror pass for all coupling-derived metrics
    call_triples = collect_remote_calls(all_asts)
    coupling_map = build_coupling_map_from_calls(call_triples)

    heatmap = heatmap_with_coupling(graph, project_path, all_asts, coupling_map)
    change_risk = change_risk_with_coupling(graph, project_path, all_asts, coupling_map)
    god_modules = god_modules_impl(graph, project_path, all_asts)
    dead_code = dead_code_with_asts(graph, project_path, all_asts)
    coupling = coupling_from_calls(call_triples)

    %{
      heatmap: heatmap,
      change_risk: change_risk,
      god_modules: god_modules,
      dead_code: dead_code,
      coupling: coupling
    }
  end

  # ============================================================================
  # Shared Call Collection (Build 99)
  # ============================================================================

  @doc """
  Single Sourceror pass over all ASTs — collects `{caller, callee, func_name}`
  triples for every remote call. Both `coupling_from_calls/1` and
  `build_coupling_map_from_calls/1` derive their output from these triples,
  eliminating the double-parse that existed before Build 99.
  """
  def collect_remote_calls(all_asts) do
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
  end

  @doc """
  Derive coupling pairs from pre-collected call triples.
  Same output as `coupling/1` but without re-parsing source files.
  """
  def coupling_from_calls(call_triples) do
    pairs =
      call_triples
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

  @doc """
  Derive coupling map from pre-collected call triples.
  Same output as `build_coupling_map/1` but without re-parsing source files.
  """
  def build_coupling_map_from_calls(call_triples) do
    call_triples
    |> Enum.group_by(fn {caller, _callee, _func} -> caller end)
    |> Enum.map(fn {caller, triples} ->
      max_to_one =
        triples
        |> Enum.frequencies_by(fn {_caller, callee, _func} -> callee end)
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      {caller, max_to_one}
    end)
    |> Map.new()
  end

  @doc """
  Dead code detection using pre-fetched ASTs.
  Same as `dead_code/2` but avoids a redundant `all_asts` fetch when called
  from `compute_cached_metrics/2`.
  """
  def dead_code_with_asts(graph, project_path, all_asts) do
    # Step 1: Get all defined functions
    all_functions = Giulia.Context.Store.list_functions(project_path, nil)

    # Step 2: Build set of behaviour callback signatures per implementer module
    impl_callbacks = collect_behaviour_callbacks(graph, project_path)

    # Step 3: Walk all ASTs to find every function call
    called_functions = collect_all_calls(all_asts)

    # Step 4: Build set of modules that have @dead_code_ignore true
    ignored_modules =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        source = case File.read(path) do
          {:ok, content} -> content
          _ -> ""
        end

        if String.contains?(source, "@dead_code_ignore") do
          (data[:modules] || []) |> Enum.map(fn mod -> mod.name end)
        else
          []
        end
      end)
      |> MapSet.new()

    # Step 5: Find dead functions
    dead =
      all_functions
      |> Enum.reject(fn func ->
        name_arity = {to_string(func.name), func.arity}

        MapSet.member?(ignored_modules, func.module) or
          MapSet.member?(@implicit_functions, name_arity) or
          MapSet.member?(impl_callbacks, {func.module, to_string(func.name), func.arity}) or
          MapSet.member?(called_functions, {func.module, to_string(func.name), func.arity}) or
          MapSet.member?(called_functions, {func.module, :local, to_string(func.name), func.arity}) or
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
end
