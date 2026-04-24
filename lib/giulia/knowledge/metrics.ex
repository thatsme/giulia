defmodule Giulia.Knowledge.Metrics do
  @moduledoc """
  Quantitative code metrics for the Knowledge Graph.

  Heatmap, change risk, god module detection, dead code analysis,
  coupling scores, and cached metric orchestration. All functions are
  stateless — they take a `%Graph{}` and/or `project_path` and return
  computed metrics.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

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
  # Heatmap (Composite module health score)
  # ============================================================================

  @spec heatmap(Graph.t(), String.t()) :: {:ok, map()}
  def heatmap(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    coupling_map = build_coupling_map(all_asts)
    heatmap_with_coupling(graph, project_path, all_asts, coupling_map)
  end

  @doc false
  @spec heatmap_with_coupling(term(), String.t(), map(), map()) :: list()
  def heatmap_with_coupling(graph, project_path, all_asts, coupling_map) do
    # Module -> file lookup
    module_files =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        Enum.map(data[:modules] || [], fn m -> {m.name, path} end)
      end)
      |> Map.new()

    # Get all module vertices
    module_vertices =
      Enum.filter(Graph.vertices(graph), fn v -> :module in Graph.vertex_labels(graph, v) end)

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
            Giulia.Tools.RunTests.has_test_file?(path, project_path)
          else
            false
          end

        # Factor 4: Max coupling
        max_coupling = Map.get(coupling_map, mod, 0)

        # Normalize each factor to 0-100
        norm_centrality = trunc(min(centrality_val / 15 * 100, 100))
        norm_complexity = trunc(min(complexity / 200 * 100, 100))
        norm_test = if has_test, do: 0, else: 100
        norm_coupling = trunc(min(max_coupling / 50 * 100, 100))

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
  # Change Risk Score
  # ============================================================================

  @spec change_risk(Graph.t(), String.t()) :: {:ok, map()}
  def change_risk(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    coupling_map = build_coupling_map(all_asts)
    change_risk_with_coupling(graph, project_path, all_asts, coupling_map)
  end

  @doc false
  @spec change_risk_with_coupling(term(), String.t(), map(), map()) :: list()
  def change_risk_with_coupling(graph, _project_path, all_asts, coupling_map) do
    # Build module -> file lookup
    module_files =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        Enum.map(data[:modules] || [], fn m -> {m.name, path} end)
      end)
      |> Map.new()

    # Get module vertices
    module_vertices =
      Enum.filter(Graph.vertices(graph), fn v -> :module in Graph.vertex_labels(graph, v) end)

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
              all_asts_data = Map.get(Map.new(all_asts), path, %{})
              functions = all_asts_data[:functions] || []
              pub = Enum.count(functions, fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)
              priv = Enum.count(functions, fn f -> f.type in [:defp, :defmacrop, :defguardp] end)
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
  # God Module Detection
  # ============================================================================

  @spec god_modules(Graph.t(), String.t()) :: {:ok, map()}
  def god_modules(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    god_modules_impl(graph, project_path, all_asts)
  end

  @doc false
  @spec god_modules_impl(term(), String.t(), map()) :: list()
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
              case Giulia.Knowledge.Topology.centrality(graph, module_name) do
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
  # Dead Code Detection
  # ============================================================================

  @spec dead_code(Graph.t(), String.t()) :: {:ok, map()}
  def dead_code(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    dead_code_with_asts(graph, project_path, all_asts)
  end

  @doc """
  Dead code detection using pre-fetched ASTs.
  Same as `dead_code/2` but avoids a redundant `all_asts` fetch when called
  from `compute_cached_metrics/2`.
  """
  @spec dead_code_with_asts(Graph.t(), String.t(), map()) :: {:ok, map()}
  def dead_code_with_asts(graph, project_path, all_asts) do
    # Step 1: Get all defined functions
    all_functions = Giulia.Context.Store.Query.list_functions(project_path, nil)

    # Step 2: Build set of behaviour callback signatures per implementer module
    impl_callbacks = Giulia.Knowledge.Behaviours.collect_behaviour_callbacks(graph, project_path)

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
          Enum.map(data[:modules] || [], fn mod -> mod.name end)
        else
          []
        end
      end)
      |> MapSet.new()

    # Step 4a: Router-declared controller actions. Any function appearing
    # as `get/post/put/patch/delete "path", Controller, :action` or as a
    # `resources` action in any router file is an entry point called by
    # Phoenix at runtime — the static call graph never sees the dispatch.
    # Extract {controller, action_name, arity=2} tuples across the project
    # and exempt them. Same signal `Builder.add_router_dispatch_edges/2`
    # uses for graph edges; exempting here short-circuits the dead_code
    # check without requiring graph traversal.
    router_actions = collect_router_actions(all_asts)

    # Step 4b: Build set of modules that are `defimpl` implementations.
    # Functions inside a defimpl are reached via protocol dispatch at
    # runtime — the static call graph never sees the call site, so
    # without this signal every defimpl function looks dead. `impl_for`
    # is set by the extractor (see `Giulia.AST.Extraction.module_node_info/1`
    # for the defimpl clause). See `feedback_dispatch_edge_synthesis.md`
    # for why this lives here rather than as a per-detector heuristic.
    protocol_impl_modules =
      all_asts
      |> Enum.flat_map(fn {_path, data} -> data[:modules] || [] end)
      |> Enum.filter(fn mod -> is_binary(Map.get(mod, :impl_for)) end)
      |> MapSet.new(& &1.name)

    # Step 5: Find dead functions
    dead =
      all_functions
      |> Enum.reject(fn func ->
        name_arity = {to_string(func.name), func.arity}

        MapSet.member?(ignored_modules, func.module) or
          MapSet.member?(protocol_impl_modules, func.module) or
          MapSet.member?(router_actions, {func.module, to_string(func.name), func.arity}) or
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

  # ============================================================================
  # Coupling Score (Function-level)
  # ============================================================================

  @spec coupling(String.t()) :: {:ok, map()}
  def coupling(project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Walk all source files and collect {caller_module, callee_module, function_name} tuples
    call_pairs =
      Enum.reduce(all_asts, [], fn {path, data}, acc ->
        caller_module = case data[:modules] do
          [%{name: name} | _] -> name
          _ -> nil
        end

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
                    callee = Enum.map_join(parts, ".", &safe_part_to_string/1)
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
  @spec compute_cached_metrics(Graph.t(), String.t()) :: map()
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
  @spec collect_remote_calls(map()) :: [{String.t(), String.t(), String.t()}]
  def collect_remote_calls(all_asts) do
    Enum.reduce(all_asts, [], fn {path, data}, acc ->
      caller_module = case data[:modules] do
        [%{name: name} | _] -> name
        _ -> nil
      end

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
                  callee = Enum.map_join(parts, ".", &safe_part_to_string/1)
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
  @spec coupling_from_calls([{String.t(), String.t(), String.t()}]) :: {:ok, map()}
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
  @spec build_coupling_map_from_calls([{String.t(), String.t(), String.t()}]) :: map()
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

  # --- Private helpers ---

  # Build a map of module -> max coupling count to any single other module
  defp build_coupling_map(all_asts) do
    call_pairs =
      Enum.reduce(all_asts, [], fn {path, data}, acc ->
        caller = case data[:modules] do
          [%{name: name} | _] -> name
          _ -> nil
        end

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
                    callee = Enum.map_join(parts, ".", &safe_part_to_string/1)
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

  # Walk all source files to collect function calls: remote (Module.func) and local (func).
  #
  # Two bugs previously lived here, both the same "first module wins"
  # class the Builder refactor closed elsewhere (commit 7792107):
  #
  # 1. Files with multiple top-level `defmodule` blocks attributed every
  #    local call to the FIRST module. A file with `defmodule MyApp.Utils.
  #    ErrorTag`, `defmodule MyApp.Utils.Interface`, and `defmodule
  #    MyApp.Utils` in that order would tag every `defp call/5` caller
  #    inside `MyApp.Utils` under the first module (`ErrorTag`) — dead_code
  #    then looked up `{MyApp.Utils, :local, call, 5}` and missed, flagging
  #    the function as dead despite obvious same-module callers.
  # 2. Multi-segment aliases weren't resolved. `alias MyApp.Ingestion`
  #    in a caller lets it reference `Ingestion.Request.build(...)`; the
  #    old code stored that as `{"Ingestion.Request", "build", 1}` because
  #    the alias map only indexed single-segment short names. dead_code's
  #    full-qualified lookup (`{"MyApp.Ingestion.Request", ...}`) missed.
  #
  # Fix for (1): `Macro.traverse/4` with an enclosing-module stack, same
  # pattern as `Giulia.AST.Extraction.extract_functions/1`. Fix for (2):
  # resolve the first segment of `parts` through the alias map, then
  # prepend the resolved full name to the remaining segments.
  @local_call_exclusions [
    :def, :defp, :defmodule, :defmacro, :defmacrop,
    :defdelegate, :defguard, :defguardp,
    :if, :unless, :case, :cond, :with, :for, :fn,
    :quote, :unquote, :import, :alias, :use, :require,
    :raise, :reraise, :throw, :try, :receive, :send,
    :spawn, :spawn_link, :super, :__block__, :__aliases__,
    :@, :&, :|>, :=, :==, :!=, :<, :>, :<=, :>=,
    :and, :or, :not, :in, :when, :{}, :%{}, :<<>>,
    :sigil_r, :sigil_s, :sigil_c, :sigil_w
  ]

  @doc false
  def collect_all_calls(all_asts) do
    Enum.reduce(all_asts, MapSet.new(), fn {path, data}, acc ->
      # Build alias map: "Schema" → "Realm.Compute.Schema"
      alias_map =
        (data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :alias end)
        |> Map.new(fn imp ->
          short = imp.module |> String.split(".") |> List.last()
          {short, imp.module}
        end)

      # Read source from disk — ETS stores metadata, not raw source.
      source =
        case File.read(path) do
          {:ok, content} -> content
          _ -> ""
        end

      case Sourceror.parse_string(source) do
        {:ok, ast} ->
          fallback_module =
            case data[:modules] do
              [%{name: name} | _] -> name
              _ -> "Unknown"
            end

          {_ast, {calls, _stack}} =
            Macro.traverse(
              ast,
              {acc, []},
              fn node, state -> call_traverse_pre(node, state, alias_map, fallback_module) end,
              &call_traverse_post/2
            )

          calls

        _ ->
          acc
      end
    end)
  end

  defp call_traverse_pre(node, {set, stack} = state, alias_map, fallback_module) do
    case safe_module_local_name(node) do
      {:ok, local_name} ->
        full_name = join_name(stack, local_name)
        {node, {set, [full_name | stack]}}

      :skip ->
        current_module = List.first(stack) || fallback_module

        case classify_call(node, alias_map, current_module) do
          {:ok, entry} -> {node, {MapSet.put(set, entry), stack}}
          :skip -> {node, state}
        end
    end
  end

  defp call_traverse_post(node, {set, stack}) do
    case safe_module_local_name(node) do
      {:ok, _} ->
        case stack do
          [_ | rest] -> {node, {set, rest}}
          [] -> {node, {set, []}}
        end

      :skip ->
        {node, {set, stack}}
    end
  end

  # Narrow-scope detector of the same module-producing nodes
  # `Extraction.module_node_info/1` handles. Kept local here rather than
  # duplicating the full return-shape — we only need the local name.
  defp safe_module_local_name({:defmodule, _meta, [{:__aliases__, _, parts} | _]})
       when is_list(parts) do
    {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}
  end

  defp safe_module_local_name({:defmodule, _meta, [atom_name | _]}) when is_atom(atom_name) do
    {:ok, Atom.to_string(atom_name)}
  end

  defp safe_module_local_name({:defprotocol, _meta, [{:__aliases__, _, parts} | _]})
       when is_list(parts) do
    {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}
  end

  defp safe_module_local_name(
         {:defimpl, _meta, [{:__aliases__, _, proto_parts}, [{for_key, type_ast}] | _]}
       )
       when is_list(proto_parts) do
    if for_key == :for or match?({:__block__, _, [:for]}, for_key) do
      proto = proto_parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")

      case type_ast_parts(type_ast) do
        {:ok, type_name} -> {:ok, "#{proto}.#{type_name}"}
        :skip -> :skip
      end
    else
      :skip
    end
  end

  defp safe_module_local_name(_), do: :skip

  defp type_ast_parts({:__aliases__, _, parts}) when is_list(parts),
    do: {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}

  defp type_ast_parts({:__block__, _, [{:__aliases__, _, parts}]}) when is_list(parts),
    do: {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}

  defp type_ast_parts(atom) when is_atom(atom), do: {:ok, Atom.to_string(atom)}

  defp type_ast_parts({:__block__, _, [atom]}) when is_atom(atom),
    do: {:ok, Atom.to_string(atom)}

  defp type_ast_parts(_), do: :skip

  defp join_name([], local), do: local
  defp join_name([top | _], local), do: "#{top}.#{local}"

  # Classify a non-module node as a remote call / local call / skip.
  defp classify_call(
         {{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args},
         alias_map,
         _current_module
       )
       when is_atom(func_name) and is_list(args) do
    {:ok, {resolve_alias(parts, alias_map), to_string(func_name), length(args)}}
  end

  defp classify_call(
         {{:., _, [mod_atom, func_name]}, _meta, args},
         _alias_map,
         _current_module
       )
       when is_atom(mod_atom) and is_atom(func_name) and is_list(args) do
    mod = String.replace_leading(Atom.to_string(mod_atom), "Elixir.", "")
    {:ok, {mod, to_string(func_name), length(args)}}
  end

  defp classify_call({func_name, _meta, args}, _alias_map, current_module)
       when is_atom(func_name) and is_list(args) and func_name not in @local_call_exclusions do
    {:ok, {current_module, :local, to_string(func_name), length(args)}}
  end

  defp classify_call(_node, _alias_map, _current_module), do: :skip

  # Resolve a multi-segment alias reference. `alias MyApp.Ingestion`
  # makes `Ingestion.Request` mean `MyApp.Ingestion.Request` — the
  # old code only indexed single-segment short names, so multi-segment
  # references fell through and landed in the call-set under the
  # unresolved short form.
  defp resolve_alias(parts, alias_map) do
    raw_segments = Enum.map(parts, &safe_part_to_string/1)

    case raw_segments do
      [first | rest] ->
        case Map.get(alias_map, first) do
          nil -> Enum.join(raw_segments, ".")
          full -> Enum.join([full | rest], ".")
        end

      [] ->
        ""
    end
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

  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)

  # ============================================================================
  # Router action collection
  # ============================================================================

  @router_verbs [:get, :post, :put, :patch, :delete, :head, :options]
  @resources_default_actions [:index, :show, :new, :create, :edit, :update, :delete]

  @doc false
  def collect_router_actions(all_asts) do
    Enum.reduce(all_asts, MapSet.new(), fn {path, data}, acc ->
      alias_map =
        (data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :alias end)
        |> Map.new(fn imp ->
          short = imp.module |> String.split(".") |> List.last()
          {short, imp.module}
        end)

      case File.read(path) do
        {:ok, source} ->
          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              routes = walk_routes_with_scope(ast, alias_map)

              Enum.reduce(routes, acc, fn {mod, name, arity}, set ->
                MapSet.put(set, {mod, name, arity})
              end)

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  # Scope-aware router walk — matches Builder Pass 9's traversal so
  # dead_code's exemption MapSet and the graph edges see exactly the
  # same controller actions.
  defp walk_routes_with_scope(ast, alias_map) do
    {_ast, {routes, _stack}} =
      Macro.traverse(
        ast,
        {[], []},
        fn node, {acc, stack} = state ->
          case scope_namespace_for_exemption(node) do
            {:ok, ns} ->
              {node, {acc, [ns | stack]}}

            :skip ->
              case route_call_for_exemption(node, alias_map, List.first(stack)) do
                {:ok, rs} -> {node, {rs ++ acc, stack}}
                :skip -> {node, state}
              end
          end
        end,
        fn node, {acc, stack} ->
          case scope_namespace_for_exemption(node) do
            {:ok, _} ->
              case stack do
                [_ | rest] -> {node, {acc, rest}}
                [] -> {node, {acc, []}}
              end

            :skip ->
              {node, {acc, stack}}
          end
        end
      )

    routes
  end

  defp scope_namespace_for_exemption({:scope, _meta, args}) when is_list(args) do
    aliased = Enum.find(args, fn
      {:__aliases__, _, _} -> true
      _ -> false
    end)

    cond do
      aliased != nil ->
        {:__aliases__, _, parts} = aliased
        {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}

      true ->
        found =
          Enum.find_value(args, fn
            opts when is_list(opts) ->
              case Keyword.get(opts, :alias) do
                {:__aliases__, _, parts} ->
                  parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")

                atom when is_atom(atom) and not is_nil(atom) ->
                  Atom.to_string(atom)

                _ ->
                  nil
              end

            _ ->
              nil
          end)

        {:ok, found}
    end
  end

  defp scope_namespace_for_exemption(_), do: :skip

  defp route_call_for_exemption(
         {verb, _meta, [_path, {:__aliases__, _, parts}, action | _rest]},
         alias_map,
         scope_ns
       )
       when verb in @router_verbs and is_atom(action) do
    controller = resolve_controller_name(parts, alias_map, scope_ns)
    {:ok, [{controller, to_string(action), 2}]}
  end

  defp route_call_for_exemption(
         {verb, _meta,
          [_path, {:__aliases__, _, parts}, {:__block__, _, [action]} | _rest]},
         alias_map,
         scope_ns
       )
       when verb in @router_verbs and is_atom(action) do
    controller = resolve_controller_name(parts, alias_map, scope_ns)
    {:ok, [{controller, to_string(action), 2}]}
  end

  defp route_call_for_exemption(
         {:resources, _meta, [_path, {:__aliases__, _, parts}]},
         alias_map,
         scope_ns
       ) do
    controller = resolve_controller_name(parts, alias_map, scope_ns)
    {:ok, Enum.map(@resources_default_actions, fn a -> {controller, to_string(a), 2} end)}
  end

  defp route_call_for_exemption(
         {:resources, _meta, [_path, {:__aliases__, _, parts}, opts]},
         alias_map,
         scope_ns
       )
       when is_list(opts) do
    controller = resolve_controller_name(parts, alias_map, scope_ns)
    actions = resources_actions_from_opts(opts)
    {:ok, Enum.map(actions, fn a -> {controller, to_string(a), 2} end)}
  end

  defp route_call_for_exemption(_node, _alias_map, _scope_ns), do: :skip

  defp resolve_controller_name(parts, alias_map, scope_ns) do
    raw = parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")

    with_scope =
      if scope_ns in [nil, ""] do
        raw
      else
        "#{scope_ns}.#{raw}"
      end

    resolve_alias_prefix_for_parts(with_scope, alias_map)
  end

  defp resolve_alias_prefix_for_parts(raw, alias_map) do
    case String.split(raw, ".", parts: 2) do
      [first] ->
        Map.get(alias_map, first, raw)

      [first, rest] ->
        case Map.get(alias_map, first) do
          nil -> raw
          full -> "#{full}.#{rest}"
        end
    end
  end

  defp resources_actions_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :only) ->
        only = Keyword.get(opts, :only, [])
        if is_list(only), do: only, else: @resources_default_actions

      Keyword.has_key?(opts, :except) ->
        except = Keyword.get(opts, :except, [])
        if is_list(except), do: @resources_default_actions -- except, else: @resources_default_actions

      true ->
        @resources_default_actions
    end
  end

end
