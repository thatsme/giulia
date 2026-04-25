defmodule Giulia.Knowledge.Insights do
  @moduledoc """
  High-level code insights and refactoring analysis for the Knowledge Graph.

  Orphan spec detection, test target mapping, logic flow tracing,
  style oracle, pre-impact checking, unprotected hub detection,
  struct lifecycle analysis, and API surface metrics.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

  alias Giulia.Knowledge.Insights.Impact

  # ============================================================================
  # Pre-Impact Check (delegated to Insights.Impact — Build 128)
  # ============================================================================

  defdelegate pre_impact_check(graph, project_path, params), to: Impact

  # ============================================================================
  # Orphan Spec Detection
  # ============================================================================

  @spec orphan_specs(String.t()) :: {:ok, list()} | {:error, term()}
  def orphan_specs(project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    orphans =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        specs = data[:specs] || []
        functions = data[:functions] || []
        modules = data[:modules] || []

        module_name =
          case modules do
            [%{name: name} | _] -> name
            _ -> "Unknown"
          end

        # Build set of defined {function_name, arity} pairs
        defined_funcs =
          functions
          |> Enum.map(fn f -> {f.name, f.arity} end)
          |> MapSet.new()

        # Find specs that don't match any defined function
        Enum.map(Enum.reject(specs, fn spec ->
          MapSet.member?(defined_funcs, {spec.function, spec.arity})
        end), fn spec ->
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

  @spec test_targets(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def test_targets(graph, module, project_path) do
    if Graph.has_vertex?(graph, module) do
      # Find the source file for this module
      direct_test = module_to_test_path(module, project_path)

      # Get direct dependents (in-neighbors = modules that depend on this one)
      dependents =
        Enum.filter(Graph.in_neighbors(graph, module), fn v -> Graph.vertex_labels(graph, v) == [:module] end)

      # Map each dependent to its test file, keep only existing ones
      dependent_tests =
        dependents
        |> Enum.map(fn dep_mod ->
          test_path = module_to_test_path(dep_mod, project_path)
          {dep_mod, test_path}
        end)
        |> Enum.filter(fn {_mod, path} -> path != nil end)

      # Collect all unique test paths that actually exist
      all_paths =
        [direct_test | Enum.map(dependent_tests, &elem(&1, 1))]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok,
       %{
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

  @spec logic_flow(term(), String.t(), term(), term()) :: {:ok, term()} | {:error, term()}
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
            steps = Enum.map(path, fn mfa -> Impact.enrich_mfa_vertex(mfa, project_path) end)
            {:ok, steps}
        end
    end
  end

  # ============================================================================
  # Style Oracle (Semantic search + quality gate)
  # ============================================================================

  @spec style_oracle(String.t(), String.t(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
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

            spec =
              case Giulia.Context.Store.Query.get_spec(project_path, module, function, arity) do
                %{spec: s} when is_binary(s) and s != "" -> s
                _ -> nil
              end

            doc =
              case Giulia.Context.Store.Query.get_function_doc(project_path, module, function, arity) do
                %{doc: d} when is_binary(d) and d != "" -> d
                _ -> nil
              end

            # Try to get source code
            source =
              if file do
                func_atom = String.to_existing_atom(function)

                case File.read(file) do
                  {:ok, content} ->
                    case Giulia.AST.Processor.slice_function(content, func_atom, arity) do
                      {:ok, src} -> src
                      _ -> nil
                    end

                  _ ->
                    nil
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

        {:ok,
         %{
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
    cfg = Giulia.Knowledge.ScoringConfig.unprotected_hubs()
    hub_threshold = Keyword.get(opts, :hub_threshold, cfg.default_hub_threshold)
    spec_threshold = Keyword.get(opts, :spec_threshold, cfg.spec_thresholds.red_max)
    yellow_threshold = cfg.spec_thresholds.yellow_max

    # Get module vertices with sufficient in-degree
    module_vertices =
      Enum.filter(Graph.vertices(graph), fn v -> :module in Graph.vertex_labels(graph, v) end)

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
          Enum.filter(Giulia.Context.Store.Query.list_functions(project_path, mod), fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)

        specs = Giulia.Context.Store.Query.list_specs(project_path, mod)
        docs = Giulia.Context.Store.Query.list_docs(project_path, mod)

        public_count = length(public_functions)
        spec_count = length(specs)
        doc_count = length(docs)

        spec_ratio = if public_count > 0, do: Float.round(spec_count / public_count, 2), else: 1.0
        doc_ratio = if public_count > 0, do: Float.round(doc_count / public_count, 2), else: 1.0

        # Check test file existence (broad detection: exact, variant, subdirectory)
        has_test =
          case Giulia.Context.Store.Query.find_module(project_path, mod) do
            {:ok, %{file: file}} ->
              Giulia.Tools.RunTests.has_test_file?(file, project_path)

            _ ->
              false
          end

        # Severity classification
        severity =
          cond do
            spec_ratio < spec_threshold -> "red"
            spec_ratio < yellow_threshold -> "yellow"
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

    {:ok,
     %{
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
    all_structs = Giulia.Context.Store.Query.list_structs(project_path)

    # Optionally filter to a single struct
    target_structs =
      if struct_filter do
        Enum.filter(all_structs, fn s -> s.module == struct_filter end)
      else
        all_structs
      end

    struct_names = MapSet.new(Enum.map(target_structs, & &1.module))

    # Walk all source files to find struct usage
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Build alias maps and collect struct references per file
    usage_data =
      Enum.reduce(all_asts, %{}, fn {path, data}, acc ->
        modules = data[:modules] || []

        file_module =
          case modules do
            [first | _] -> first.name
            _ -> nil
          end

        if is_nil(file_module) do
          acc
        else
          source =
            case File.read(path) do
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
        users = MapSet.to_list(Map.get(usage_data, defining_mod, MapSet.new()))

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

  @spec api_surface(String.t()) :: {:ok, list()} | {:error, term()}
  def api_surface(project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    modules =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        modules = data[:modules] || []
        functions = data[:functions] || []

        case modules do
          [mod | _] ->
            public =
              Enum.count(functions, fn f ->
                f.type in [:def, :defmacro, :defdelegate, :defguard]
              end)

            private = Enum.count(functions, fn f -> f.type in [:defp, :defmacrop, :defguardp] end)
            total = public + private
            ratio = if total > 0, do: Float.round(public / total, 2), else: 0.0

            [
              %{
                module: mod.name,
                public: public,
                private: private,
                total: total,
                ratio: ratio,
                file: path
              }
            ]

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
    case Giulia.Context.Store.Query.find_module(project_path, module_name) do
      {:ok, %{file: source_file}} ->
        Giulia.Tools.RunTests.find_test_file(source_file, project_path)

      _ ->
        nil
    end
  end

  # Safely convert AST alias parts to strings.
  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)
end
