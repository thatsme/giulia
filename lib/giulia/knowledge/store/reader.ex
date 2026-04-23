defmodule Giulia.Knowledge.Store.Reader do
  @moduledoc """
  Direct ETS reads for Knowledge Graph queries.

  All functions read the graph and metric caches directly from ETS
  (`:giulia_knowledge_graphs`) without going through the GenServer process.
  This eliminates serialization for read-heavy workloads — all callers
  can read concurrently.

  Write coordination remains in `Giulia.Knowledge.Store` (the GenServer).
  """

  alias Giulia.Knowledge.Analyzer

  @table :giulia_knowledge_graphs

  # ============================================================================
  # Private helpers — ETS access
  # ============================================================================

  defp get_graph(project_path) do
    case :ets.lookup(@table, {:graph, project_path}) do
      [{_, graph}] -> graph
      [] -> Graph.new(type: :directed)
    end
  end

  defp get_cached(project_path, metric) do
    case :ets.lookup(@table, {:metrics, project_path}) do
      [{_, metrics}] -> Map.get(metrics, metric)
      [] -> nil
    end
  end

  defp put_cached(project_path, metric, value) do
    current =
      case :ets.lookup(@table, {:metrics, project_path}) do
        [{_, metrics}] -> metrics
        [] -> %{}
      end

    :ets.insert(@table, {{:metrics, project_path}, Map.put(current, metric, value)})
  end

  # ============================================================================
  # Topology queries (8) — ETS read + Analyzer
  # ============================================================================

  @spec stats(String.t()) :: map()
  def stats(project_path) do
    project_path |> get_graph() |> Analyzer.stats()
  end

  @spec centrality(String.t(), String.t()) :: {:ok, map()} | {:error, {:not_found, String.t()}}
  def centrality(project_path, module) do
    project_path |> get_graph() |> Analyzer.centrality(module)
  end

  @spec dependents(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, {:not_found, String.t()}}
  def dependents(project_path, module) do
    project_path |> get_graph() |> Analyzer.dependents(module)
  end

  @spec dependencies(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, {:not_found, String.t()}}
  def dependencies(project_path, module) do
    project_path |> get_graph() |> Analyzer.dependencies(module)
  end

  @spec impact_map(String.t(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, tuple()}
  def impact_map(project_path, vertex_id, depth) do
    project_path |> get_graph() |> Analyzer.impact_map(vertex_id, depth)
  end

  @spec trace_path(String.t(), String.t(), String.t()) ::
          {:ok, :no_path | [String.t()]} | {:error, {:not_found, String.t()}}
  def trace_path(project_path, from, to) do
    project_path |> get_graph() |> Analyzer.trace_path(from, to)
  end

  @spec find_cycles(String.t()) :: {:ok, map()}
  def find_cycles(project_path) do
    project_path |> get_graph() |> Analyzer.cycles()
  end

  @spec find_fan_in_out(String.t()) :: {:ok, map()}
  def find_fan_in_out(project_path) do
    graph = get_graph(project_path)
    Analyzer.fan_in_out(graph, project_path)
  end

  # ============================================================================
  # Cached metrics (5) — ETS cache-first, cold fallback computes + writes
  # ============================================================================

  @spec heatmap(String.t()) :: {:ok, map()}
  def heatmap(project_path) do
    case get_cached(project_path, :heatmap) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.heatmap(graph, project_path)
        put_cached(project_path, :heatmap, result)
        result

      cached ->
        cached
    end
  end

  @spec change_risk_score(String.t()) :: {:ok, map()}
  def change_risk_score(project_path) do
    case get_cached(project_path, :change_risk) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.change_risk(graph, project_path)
        put_cached(project_path, :change_risk, result)
        result

      cached ->
        cached
    end
  end

  @spec find_god_modules(String.t()) :: {:ok, map()}
  def find_god_modules(project_path) do
    case get_cached(project_path, :god_modules) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.god_modules(graph, project_path)
        put_cached(project_path, :god_modules, result)
        result

      cached ->
        cached
    end
  end

  @spec find_dead_code(String.t()) :: {:ok, map()}
  def find_dead_code(project_path) do
    case get_cached(project_path, :dead_code) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.dead_code(graph, project_path)
        put_cached(project_path, :dead_code, result)
        result

      cached ->
        cached
    end
  end

  @spec find_coupling(String.t()) :: {:ok, map()}
  def find_coupling(project_path) do
    case get_cached(project_path, :coupling) do
      nil ->
        result = Analyzer.coupling(project_path)
        put_cached(project_path, :coupling, result)
        result

      cached ->
        cached
    end
  end

  # ============================================================================
  # Non-cached analysis (4) — direct Analyzer call, no graph needed
  # ============================================================================

  @spec find_orphan_specs(String.t()) :: {:ok, map()}
  def find_orphan_specs(project_path) do
    Analyzer.orphan_specs(project_path)
  end

  @spec find_api_surface(String.t()) :: {:ok, map()}
  def find_api_surface(project_path) do
    Analyzer.api_surface(project_path)
  end

  @spec style_oracle(String.t(), String.t(), non_neg_integer()) :: {:ok, map()}
  def style_oracle(project_path, query, top_k) do
    Analyzer.style_oracle(project_path, query, top_k)
  end

  @spec struct_lifecycle(String.t(), String.t()) :: {:ok, map()}
  def struct_lifecycle(project_path, struct_module) do
    Analyzer.struct_lifecycle(project_path, struct_module)
  end

  @spec find_conventions(String.t()) :: {:ok, map()}
  def find_conventions(project_path) do
    # No caching — conventions depend on all_asts which changes on every scan.
    # Stale cache caused 0-violation ghost results after re-indexing.
    Analyzer.conventions(project_path)
  end

  @spec find_conventions(String.t(), String.t() | keyword()) :: {:ok, map()}
  def find_conventions(project_path, module_filter_or_opts) do
    # Module-filtered and suppressed queries are not cached (params vary per request)
    Analyzer.conventions(project_path, module_filter_or_opts)
  end

  # ============================================================================
  # Graph-dependent analysis (6) — ETS read + Analyzer
  # ============================================================================

  @spec find_unprotected_hubs(String.t(), keyword()) :: {:ok, map()}
  def find_unprotected_hubs(project_path, opts) do
    graph = get_graph(project_path)
    Analyzer.find_unprotected_hubs(graph, project_path, opts)
  end

  @spec get_test_targets(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_test_targets(project_path, module) do
    graph = get_graph(project_path)
    Analyzer.test_targets(graph, module, project_path)
  end

  @spec check_behaviour_integrity(String.t(), String.t()) ::
          {:ok, :consistent} | {:error, :not_found | [map()]}
  def check_behaviour_integrity(project_path, behaviour) do
    graph = get_graph(project_path)
    Analyzer.behaviour_integrity(graph, behaviour, project_path)
  end

  @spec check_all_behaviours(String.t()) :: {:ok, :consistent} | {:error, map()}
  def check_all_behaviours(project_path) do
    graph = get_graph(project_path)
    Analyzer.all_behaviours(graph, project_path)
  end

  @spec logic_flow(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def logic_flow(project_path, from_mfa, to_mfa) do
    graph = get_graph(project_path)
    Analyzer.logic_flow(graph, project_path, from_mfa, to_mfa)
  end

  @spec pre_impact_check(String.t(), map()) :: {:ok, map()}
  def pre_impact_check(project_path, params) do
    graph = get_graph(project_path)
    Analyzer.pre_impact_check(graph, project_path, params)
  end

  # ============================================================================
  # Bulk extraction — for ArcadeDB Indexer and future consumers
  # ============================================================================

  @doc """
  All module vertices in the graph as a list of maps.

  Returns `{:ok, [%{name: "Giulia.Foo", ...}]}`.
  Each map includes the module name and any metadata available from
  the Context.Store AST data (file path, line, function count).
  """
  @spec all_modules(String.t()) :: {:ok, [map()]}
  def all_modules(project_path) do
    graph = get_graph(project_path)

    modules =
      graph
      |> Graph.vertices()
      |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)
      |> Enum.map(fn name ->
        # Enrich with AST metadata if available
        ast_meta = get_module_meta(project_path, name)

        # Enrich with complexity and coupling from graph + AST
        functions = get_module_functions(project_path, name)
        complexity_score = Enum.sum(Enum.map(functions, fn f -> f[:complexity] || 0 end))
        function_count = length(functions)

        in_degree = graph |> Graph.in_edges(name) |> length()
        out_degree = graph |> Graph.out_edges(name) |> length()

        Map.merge(%{
          name: name,
          complexity_score: complexity_score,
          function_count: function_count,
          dep_in: in_degree,
          dep_out: out_degree
        }, ast_meta)
      end)

    {:ok, modules}
  end

  @doc """
  All function vertices in the graph as a list of maps.

  Returns `{:ok, [%{name: "Giulia.Foo.bar/2", module: "Giulia.Foo", function: "bar", arity: 2}]}`.
  """
  @spec all_functions(String.t()) :: {:ok, [map()]}
  def all_functions(project_path) do
    graph = get_graph(project_path)

    functions =
      graph
      |> Graph.vertices()
      |> Enum.filter(fn v -> :function in Graph.vertex_labels(graph, v) end)
      |> Enum.map(fn name ->
        {mod, func, arity} = parse_mfa(name)
        complexity = get_function_complexity(project_path, mod, func, arity)
        %{name: name, module: mod, function: func, arity: arity, complexity: complexity}
      end)

    {:ok, functions}
  end

  @doc """
  All dependency edges in the graph as a list of `{from, to, type}` tuples.

  Returns `{:ok, [{"Giulia.Foo", "Giulia.Bar", :depends_on}, ...]}`.
  Only includes module-level edges (:depends_on, :calls, :implements,
  :references, :semantic).
  """
  @spec all_dependencies(String.t()) :: {:ok, [{String.t(), String.t(), atom()}]}
  def all_dependencies(project_path) do
    {:ok, edges_between(project_path, :module)}
  end

  @doc """
  All function-level :calls edges in the graph as MFA→MFA tuples.

  Returns `{:ok, [{"Foo.bar/2", "Baz.qux/1", :calls}, ...]}`.
  Only includes edges where both endpoints are :function vertices. This is
  the edge set that L3 CALLS ingestion expects (per Arcade schema, CALLS
  edges run between Function vertices, not Module vertices).
  """
  @spec all_function_call_edges(String.t()) :: {:ok, [{String.t(), String.t(), atom()}]}
  def all_function_call_edges(project_path) do
    edges = edges_between(project_path, :function) |> Enum.filter(fn {_, _, l} -> l == :calls end)
    {:ok, edges}
  end

  @doc """
  All function-level :calls edges with resolution-path (`via`) metadata.

  Returns `{:ok, [{from_mfa, to_mfa, :calls, via}, ...]}` where via records
  how the target module was resolved at extraction time — one of
  :direct | :alias_resolved | :erlang_atom | :local. Used by the stratified
  sample-identity check to cover the high-risk resolution buckets.
  """
  @spec all_function_call_edges_with_via(String.t()) ::
          {:ok, [{String.t(), String.t(), atom(), atom()}]}
  def all_function_call_edges_with_via(project_path) do
    edges =
      edges_between_raw(project_path, :function)
      |> Enum.flat_map(fn {v1, v2, raw_label} ->
        case raw_label do
          {:calls, via} -> [{v1, v2, :calls, via}]
          _ -> []
        end
      end)

    {:ok, edges}
  end

  # Enumerate edges whose both endpoints have the given vertex label,
  # normalizing compound labels back to the atom head for public 3-tuple API.
  defp edges_between(project_path, vertex_label) do
    edges_between_raw(project_path, vertex_label)
    |> Enum.map(fn {v1, v2, raw_label} -> {v1, v2, normalize_label(raw_label)} end)
  end

  defp edges_between_raw(project_path, vertex_label) do
    graph = get_graph(project_path)

    vertex_set =
      graph
      |> Graph.vertices()
      |> Enum.filter(fn v -> vertex_label in Graph.vertex_labels(graph, v) end)
      |> MapSet.new()

    graph
    |> Graph.edges()
    |> Enum.filter(fn edge -> edge.v1 in vertex_set and edge.v2 in vertex_set end)
    |> Enum.map(fn edge -> {edge.v1, edge.v2, edge.label} end)
  end

  defp normalize_label({:semantic, _reason}), do: :semantic
  defp normalize_label({:calls, _via}), do: :calls
  defp normalize_label(other), do: other

  # --- Helpers for bulk extraction ---

  defp get_module_functions(project_path, module_name) do
    try do
      case :ets.match_object(Giulia.Context.Store, {{:ast, project_path, :_}, :_}) do
        entries ->
          Enum.flat_map(entries, fn {{:ast, _proj, _file}, data} ->
            modules = data[:modules] || []

            case Enum.find(modules, fn m -> m.name == module_name end) do
              nil -> []
              mod -> mod[:functions] || []
            end
          end)
      end
    rescue
      ArgumentError -> []
    end
  end

  defp get_function_complexity(project_path, module_name, func_name, arity) do
    functions = get_module_functions(project_path, module_name)

    case Enum.find(functions, fn f ->
      to_string(f[:name] || f.name) == to_string(func_name) and
        (f[:arity] || f.arity) == arity
    end) do
      nil -> 0
      f -> f[:complexity] || 0
    end
  end

  defp get_module_meta(project_path, module_name) do
    # Try to find the module in Context.Store AST data
    try do
      case :ets.match_object(Giulia.Context.Store, {{:ast, project_path, :_}, :_}) do
        entries ->
          Enum.find_value(entries, %{}, fn {{:ast, _proj, file_path}, data} ->
            modules = data[:modules] || []

            case Enum.find(modules, fn m -> m.name == module_name end) do
              nil -> nil
              mod -> %{path: file_path, line: mod[:line] || mod.line}
            end
          end)
      end
    rescue
      ArgumentError -> %{}
    end
  end

  defp parse_mfa(name) do
    case Regex.run(~r/^(.+)\.([^.]+)\/(\d+)$/, name) do
      [_, mod, func, arity] -> {mod, func, elem(Integer.parse(arity), 0)}
      _ -> {name, nil, nil}
    end
  end

  # ============================================================================
  # Direct graph operations (2)
  # ============================================================================

  @spec graph(String.t()) :: Graph.t()
  def graph(project_path) do
    get_graph(project_path)
  end

  @spec get_implementers(String.t(), String.t()) :: {:ok, [String.t()]}
  def get_implementers(project_path, behaviour) do
    graph = get_graph(project_path)

    implementers =
      Graph.in_edges(graph, behaviour)
      |> Enum.filter(fn edge -> edge.label == :implements end)
      |> Enum.map(fn edge -> edge.v1 end)
      |> Enum.uniq()

    {:ok, implementers}
  end
end
