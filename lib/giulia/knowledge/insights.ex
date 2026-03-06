defmodule Giulia.Knowledge.Insights do
  @moduledoc """
  High-level code insights and refactoring analysis for the Knowledge Graph.

  Orphan spec detection, test target mapping, logic flow tracing,
  style oracle, pre-impact checking, unprotected hub detection,
  struct lifecycle analysis, and API surface metrics.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

  alias Giulia.Knowledge.Topology

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
        module_name = case modules do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

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

  # ============================================================================
  # Unprotected Hub Detection
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
          |> Enum.filter(fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)

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
  # Struct Lifecycle Tracing
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
                    raw_name = Enum.map_join(parts, ".", &safe_part_to_string/1)
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
            public = Enum.count(functions, fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)
            private = Enum.count(functions, fn f -> f.type in [:defp, :defmacrop, :defguardp] end)
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

  # --- Private helpers ---

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
      case Topology.dependents(graph, module) do
        {:ok, deps} ->
          # Hub penalty
          hub_penalty = case Topology.centrality(graph, module) do
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
        case Topology.centrality(graph, mod) do
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
      case Topology.centrality(graph, mod) do
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

  # Safely convert AST alias parts to strings.
  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)
end
