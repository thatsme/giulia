defmodule Giulia.Intelligence.Preflight do
  @moduledoc """
  Contract Checklist Pipeline — Semantic Guardrails for Planning.

  Pure functional module (no GenServer). Stateless pipeline.

  Given a natural language prompt, discovers relevant modules via semantic search
  and returns a structured Contract Checklist per module — 6 contract sections:

  1. Behaviour Contract — callbacks defined/implemented, integrity
  2. Type Contract — specs, types, coverage
  3. Data Contract — struct fields, dependents
  4. Macro Contract — use directives, known implications
  5. Topology — centrality, impact, change risk
  6. Semantic Integrity — similarity to prompt, drift detection

  One call replaces the 4 separate queries SKILL.md mandates for planning.
  """

  alias Giulia.Context.Store
  alias Giulia.Intelligence.SemanticIndex
  alias Giulia.Knowledge.MacroMap
  alias Giulia.Knowledge.Store, as: KnowledgeStore

  require Logger

  @embedding_dims 384
  @drift_threshold 0.3

  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, project_path, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 5)
    depth = Keyword.get(opts, :depth, 2)

    # Step 1: Discover — semantic search for target modules
    {modules, semantic_available, query_vector} = discover(prompt, project_path, top_k)

    # Step 2: Pre-compute change risk (expensive, call once)
    risk_map = precompute_change_risk(project_path)

    # Step 3: Per-module — build 6 contract sections
    enriched =
      Enum.map(modules, fn mod ->
        build_module_contracts(mod, project_path, depth, risk_map, query_vector)
      end)

    # Step 4: Summarize
    summary = build_summary(enriched)

    # Step 5: Suggest relevant API tools (Build 100)
    suggested_tools = suggest_tools(query_vector)

    {:ok, %{
      prompt: prompt,
      project_path: project_path,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      semantic_available: semantic_available,
      modules: enriched,
      summary: summary,
      suggested_tools: suggested_tools
    }}
  rescue
    e ->
      Logger.warning("Preflight: Pipeline error: #{Exception.message(e)}")
      {:error, {:pipeline_error, Exception.message(e)}}
  end

  # ============================================================================
  # Stage 1: Discover
  # ============================================================================

  defp discover(prompt, project_path, top_k) do
    if SemanticIndex.available?() do
      case SemanticIndex.search(project_path, prompt, top_k) do
        {:ok, %{modules: modules}} when modules != [] ->
          # Also embed the prompt for semantic integrity checks
          query_vector = embed_prompt(prompt)
          {modules, true, query_vector}

        {:ok, _} ->
          {[], true, nil}

        {:error, _reason} ->
          {[], false, nil}
      end
    else
      {[], false, nil}
    end
  end

  defp embed_prompt(prompt) do
    try do
      [result] = Nx.Serving.batched_run(Giulia.EmbeddingServing, [prompt])
      result.embedding
    rescue
      _ -> nil
    end
  end

  # ============================================================================
  # Stage 2: Pre-compute change risk
  # ============================================================================

  defp precompute_change_risk(project_path) do
    case KnowledgeStore.change_risk_score(project_path) do
      {:ok, %{modules: ranked}} ->
        ranked
        |> Enum.with_index(1)
        |> Map.new(fn {entry, rank} -> {entry.module, %{score: entry.score, rank: rank}} end)

      _ ->
        %{}
    end
  end

  # ============================================================================
  # Stage 3: Per-module contract builder
  # ============================================================================

  defp build_module_contracts(mod, project_path, depth, risk_map, query_vector) do
    module_name = mod.id
    file = mod.metadata[:file] || mod.metadata["file"]

    %{
      module: module_name,
      file: file,
      relevance_score: mod.score,
      behaviour_contract: safe_build(:behaviour, fn -> behaviour_contract(project_path, module_name) end),
      type_contract: safe_build(:type, fn -> type_contract(project_path, module_name) end),
      data_contract: safe_build(:data, fn -> data_contract(project_path, module_name) end),
      macro_contract: safe_build(:macro, fn -> macro_contract(project_path, module_name) end),
      topology: safe_build(:topology, fn -> topology_contract(project_path, module_name, depth, risk_map) end),
      semantic_integrity: safe_build(:semantic, fn -> semantic_integrity(project_path, module_name, query_vector) end),
      runtime_alert: safe_build(:runtime, fn -> runtime_alert(project_path, module_name) end)
    }
  end

  defp safe_build(section, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Preflight: Error building #{section} contract: #{Exception.message(e)}")
      nil
  end

  # ============================================================================
  # Contract 1: Behaviour
  # ============================================================================

  defp behaviour_contract(project_path, module_name) do
    # Callbacks this module DEFINES
    all_callbacks = Store.list_callbacks(project_path, module_name)
    defines_callbacks = Enum.map(all_callbacks, fn cb -> "#{cb.function}/#{cb.arity}" end)

    # Optional callbacks this module defines
    optional_callbacks =
      all_callbacks
      |> Enum.filter(fn cb -> Map.get(cb, :optional, false) == true end)
      |> Enum.map(fn cb -> "#{cb.function}/#{cb.arity}" end)

    # Behaviours this module IMPLEMENTS (use directives)
    implements =
      case Store.find_module(project_path, module_name) do
        {:ok, %{ast_data: ast_data}} ->
          (ast_data[:imports] || [])
          |> Enum.filter(fn imp -> imp.type == :use end)
          |> Enum.map(fn imp -> imp.module end)

        _ ->
          []
      end

    # Behaviour integrity check with enriched fracture data
    {integrity, missing_callbacks, optional_omitted, heuristic_injected} =
      case KnowledgeStore.check_behaviour_integrity(project_path, module_name) do
        {:ok, :consistent} ->
          if defines_callbacks == [] do
            {"not_a_behaviour", [], [], []}
          else
            # Check if any optionals were omitted (still consistent)
            has_optionals = optional_callbacks != []
            status = if has_optionals, do: "consistent_with_optionals", else: "consistent"
            {status, [], [], []}
          end

        {:error, fractures} when is_list(fractures) ->
          missing =
            Enum.flat_map(fractures, fn frac ->
              Enum.map(Map.get(frac, :missing, []), fn {name, arity} ->
                "#{frac.implementer}: #{name}/#{arity}"
              end)
            end)

          opt_omitted =
            Enum.flat_map(fractures, fn frac ->
              Enum.map(Map.get(frac, :optional_omitted, []), fn {name, arity} ->
                "#{frac.implementer}: #{name}/#{arity}"
              end)
            end)

          heuristic =
            Enum.flat_map(fractures, fn frac ->
              Enum.map(Map.get(frac, :heuristic_injected, []), fn {name, arity} ->
                "#{frac.implementer}: #{name}/#{arity}"
              end)
            end)

          # 4-level status
          status = cond do
            missing != [] -> "fractured"
            heuristic != [] -> "heuristic_match"
            opt_omitted != [] -> "consistent_with_optionals"
            true -> "consistent"
          end

          {status, missing, opt_omitted, heuristic}

        _ ->
          if defines_callbacks == [] do
            {"not_a_behaviour", [], [], []}
          else
            {"consistent", [], [], []}
          end
      end

    %{
      defines_callbacks: defines_callbacks,
      optional_callbacks: optional_callbacks,
      implements: implements,
      integrity: integrity,
      missing_callbacks: missing_callbacks,
      optional_omitted: optional_omitted,
      heuristic_injected: heuristic_injected
    }
  end

  # ============================================================================
  # Contract 2: Type
  # ============================================================================

  defp type_contract(project_path, module_name) do
    specs = Store.list_specs(project_path, module_name)
    types = Store.list_types(project_path, module_name)

    public_functions =
      Store.list_functions(project_path, module_name)
      |> Enum.filter(fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)

    public_count = length(public_functions)
    spec_count = length(specs)

    spec_coverage =
      if public_count > 0 do
        Float.round(spec_count / public_count, 2)
      else
        0.0
      end

    spec_list =
      Enum.map(specs, fn spec ->
        spec_string =
          case spec do
            %{spec: s} when is_binary(s) -> s
            _ -> "#{spec.function}/#{spec.arity}"
          end

        %{function: "#{spec.function}/#{spec.arity}", spec: spec_string}
      end)

    type_list =
      Enum.map(types, fn type ->
        "#{type.name}/#{type.arity}"
      end)

    %{
      specs: spec_list,
      types: type_list,
      spec_coverage: spec_coverage
    }
  end

  # ============================================================================
  # Contract 3: Data
  # ============================================================================

  defp data_contract(project_path, module_name) do
    struct_info = Store.get_struct(project_path, module_name)

    dependents_count =
      case KnowledgeStore.dependents(project_path, module_name) do
        {:ok, deps} -> length(deps)
        _ -> 0
      end

    case struct_info do
      %{fields: fields} ->
        %{
          has_struct: true,
          fields: fields,
          dependents_count: dependents_count
        }

      nil ->
        %{
          has_struct: false,
          fields: nil,
          dependents_count: dependents_count
        }
    end
  end

  # ============================================================================
  # Contract 4: Macro
  # ============================================================================

  defp macro_contract(project_path, module_name) do
    use_directives =
      case Store.find_module(project_path, module_name) do
        {:ok, %{ast_data: ast_data}} ->
          (ast_data[:imports] || [])
          |> Enum.filter(fn imp -> imp.type == :use end)
          |> Enum.map(fn imp ->
            %{module: imp.module, line: imp.line}
          end)

        _ ->
          []
      end

    # Precise function-level implications from MacroMap
    known_implications =
      use_directives
      |> Enum.flat_map(fn directive ->
        MacroMap.injected_functions(directive.module)
      end)
      |> Enum.uniq()
      |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)

    %{
      use_directives: use_directives,
      known_implications: known_implications
    }
  end

  # ============================================================================
  # Contract 5: Topology
  # ============================================================================

  defp topology_contract(project_path, module_name, depth, risk_map) do
    centrality =
      case KnowledgeStore.centrality(project_path, module_name) do
        {:ok, %{in_degree: in_deg, out_degree: out_deg}} ->
          %{in_degree: in_deg, out_degree: out_deg}

        _ ->
          nil
      end

    dependents =
      case KnowledgeStore.dependents(project_path, module_name) do
        {:ok, deps} -> deps
        _ -> []
      end

    impact =
      case KnowledgeStore.impact_map(project_path, module_name, depth) do
        {:ok, result} ->
          upstream = Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end)
          downstream = Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end)
          %{upstream: upstream, downstream: downstream}

        _ ->
          %{upstream: [], downstream: []}
      end

    change_risk = Map.get(risk_map, module_name)

    %{
      centrality: centrality,
      dependents: dependents,
      change_risk: change_risk,
      impact: impact
    }
  end

  # ============================================================================
  # Contract 6: Semantic Integrity
  # ============================================================================

  defp semantic_integrity(project_path, module_name, query_vector) do
    # Get moduledoc excerpt
    moduledoc_excerpt =
      case Store.get_moduledoc(project_path, module_name) do
        {:ok, doc} when is_binary(doc) ->
          String.slice(doc, 0, 200)

        _ ->
          nil
      end

    # Compute similarity between prompt and module embedding
    {similarity, drift_flag} =
      if query_vector do
        compute_module_similarity(project_path, module_name, query_vector, moduledoc_excerpt)
      else
        {nil, false}
      end

    %{
      moduledoc_excerpt: moduledoc_excerpt,
      similarity_to_prompt: similarity,
      drift_flag: drift_flag
    }
  end

  defp compute_module_similarity(project_path, module_name, query_vector, moduledoc_excerpt) do
    case Store.get_embeddings(project_path, :module) do
      {:ok, entries} ->
        case Enum.find(entries, fn e -> e.id == module_name end) do
          %{vector: vec_binary} ->
            module_vec = Nx.from_binary(vec_binary, :f32) |> Nx.reshape({@embedding_dims})
            # Both L2-normalized → cosine = dot product
            similarity = Nx.dot(module_vec, query_vector) |> Nx.to_number() |> Float.round(4)

            drift_flag =
              similarity < @drift_threshold and moduledoc_excerpt != nil

            {similarity, drift_flag}

          nil ->
            {nil, false}
        end

      :error ->
        {nil, false}
    end
  end

  # ============================================================================
  # Contract 7: Runtime Alert (Build 92 — Live Performance Alert)
  # ============================================================================

  defp runtime_alert(project_path, module_name) do
    if Giulia.Runtime.Collector.active?() do
      case Giulia.Runtime.Inspector.hot_spots(:local, project_path) do
        {:ok, spots} ->
          case Enum.find(spots, fn s -> s.module == module_name end) do
            nil ->
              nil

            spot ->
              %{
                live: true,
                reductions_pct: spot.reductions_pct,
                memory_kb: spot.memory_kb,
                message_queue: spot.message_queue,
                alert: "LIVE PERFORMANCE ALERT: #{spot.reductions_pct}% of system reductions, " <>
                       "#{spot.memory_kb}KB memory, message queue #{spot.message_queue}"
              }
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  # ============================================================================
  # Stage 4: Summary
  # ============================================================================

  defp build_summary(modules) do
    total = length(modules)

    high_risk_count =
      Enum.count(modules, fn mod ->
        case mod.topology do
          %{change_risk: %{rank: rank}} when rank <= 5 -> true
          _ -> false
        end
      end)

    hub_count =
      Enum.count(modules, fn mod ->
        case mod.topology do
          %{centrality: %{in_degree: deg}} when deg >= 3 -> true
          _ -> false
        end
      end)

    integrity_status =
      modules
      |> Enum.map(fn mod ->
        case mod.behaviour_contract do
          %{integrity: status} -> status
          _ -> "not_a_behaviour"
        end
      end)
      |> Enum.reject(fn s -> s in ["not_a_behaviour", nil] end)
      |> case do
        [] -> "consistent"
        statuses ->
          cond do
            "fractured" in statuses -> "fractured"
            "heuristic_match" in statuses -> "heuristic_match"
            "consistent_with_optionals" in statuses -> "consistent_with_optionals"
            true -> "consistent"
          end
      end

    semantic_drift_count =
      Enum.count(modules, fn mod ->
        case mod.semantic_integrity do
          %{drift_flag: true} -> true
          _ -> false
        end
      end)

    %{
      total_modules: total,
      high_risk_count: high_risk_count,
      hub_count: hub_count,
      integrity_status: integrity_status,
      semantic_drift_count: semantic_drift_count
    }
  end

  # ============================================================================
  # Stage 5: Suggest Tools (Build 100)
  # ============================================================================

  defp suggest_tools(nil), do: []

  defp suggest_tools(query_vector) do
    case SemanticIndex.search_skills(query_vector, 5) do
      {:ok, skills} -> skills
      {:error, _} -> []
    end
  end
end
