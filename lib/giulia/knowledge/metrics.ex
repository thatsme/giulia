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
  # Change Risk Score
  # ============================================================================

  @spec change_risk(Graph.t(), String.t()) :: {:ok, map()}
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
    all_functions = Giulia.Context.Store.list_functions(project_path, nil)

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

  # Walk all source files to collect function calls: remote (Module.func) and local (func)
  defp collect_all_calls(all_asts) do
    Enum.reduce(all_asts, MapSet.new(), fn {path, data}, acc ->
      module_name = case data[:modules] do
        [%{name: name} | _] -> name
        _ -> "Unknown"
      end

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
                raw_mod = Enum.map_join(parts, ".", &safe_part_to_string/1)
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

  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)
end
