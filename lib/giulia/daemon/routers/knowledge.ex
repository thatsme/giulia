defmodule Giulia.Daemon.Routers.Knowledge do
  @moduledoc """
  Routes for the Knowledge Graph (project topology analysis).

  Forwarded from `/api/knowledge` — paths here are relative to that prefix.
  This is the largest sub-router with 23 routes.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # GET /api/knowledge/stats — Graph statistics
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get Knowledge Graph statistics (vertices, edges, components, hubs)",
    endpoint: "GET /api/knowledge/stats",
    params: %{path: :required},
    returns: "JSON graph stats with top hub modules",
    category: "knowledge"
  }
  get "/stats" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        stats = Giulia.Knowledge.Store.stats(project_path)
        hubs = Enum.map(stats.hubs || [], fn {name, degree} -> %{module: name, degree: degree} end)
        send_json(conn, 200, %{stats | hubs: hubs})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/dependents — Who depends on module X
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find all modules that depend on a given module (downstream blast radius)",
    endpoint: "GET /api/knowledge/dependents",
    params: %{path: :required, module: :required},
    returns: "JSON list of dependent modules with count",
    category: "knowledge"
  }
  get "/dependents" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.dependents(project_path, module) do
            {:ok, deps} ->
              send_json(conn, 200, %{module: module, dependents: deps, count: length(deps)})

            {:error, {:not_found, _}} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/dependencies — What module X depends on
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find all modules that a given module depends on (upstream dependencies)",
    endpoint: "GET /api/knowledge/dependencies",
    params: %{path: :required, module: :required},
    returns: "JSON list of dependency modules with count",
    category: "knowledge"
  }
  get "/dependencies" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.dependencies(project_path, module) do
            {:ok, deps} ->
              send_json(conn, 200, %{module: module, dependencies: deps, count: length(deps)})

            {:error, {:not_found, _}} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/centrality — Hub detection score
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get centrality score for a module (in-degree, out-degree, hub detection)",
    endpoint: "GET /api/knowledge/centrality",
    params: %{path: :required, module: :required},
    returns: "JSON centrality data with in/out degree and dependents list",
    category: "knowledge"
  }
  get "/centrality" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.centrality(project_path, module) do
            {:ok, result} ->
              send_json(conn, 200, Map.put(result, :module, module))

            {:error, {:not_found, _}} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/impact — Upstream + downstream at depth N
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get full impact map (upstream + downstream dependencies at given depth)",
    endpoint: "GET /api/knowledge/impact",
    params: %{path: :required, module: :required, depth: :optional},
    returns: "JSON impact map with upstream, downstream, and function-level edges",
    category: "knowledge"
  }
  get "/impact" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]
        depth = parse_int_param(conn.query_params["depth"], 2)

        if module do
          case Giulia.Knowledge.Store.impact_map(project_path, module, depth) do
            {:ok, result} ->
              upstream = Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end)
              downstream = Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end)
              func_edges = Enum.map(result.function_edges, fn {name, targets} ->
                %{function: name, calls: targets}
              end)
              send_json(conn, 200, %{result | upstream: upstream, downstream: downstream, function_edges: func_edges})

            {:error, {:not_found, _, suggestions, graph_info}} ->
              send_json(conn, 404, %{
                error: "Module not found in graph",
                module: module,
                suggestions: suggestions,
                graph_info: graph_info
              })
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/integrity — Behaviour-implementer integrity check
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check behaviour-implementer integrity (missing/extra callbacks)",
    endpoint: "GET /api/knowledge/integrity",
    params: %{path: :required},
    returns: "JSON with consistent/fractured status and fracture details",
    category: "knowledge"
  }
  get "/integrity" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.check_all_behaviours(project_path) do
          {:ok, :consistent} ->
            send_json(conn, 200, %{status: "consistent", fractures: []})

          {:error, fractures} when is_map(fractures) ->
            formatted =
              Enum.map(fractures, fn {behaviour, impl_fractures} ->
                %{
                  behaviour: behaviour,
                  fractures: Enum.map(impl_fractures, fn frac ->
                    format_fracture(frac)
                  end)
                }
              end)

            send_json(conn, 200, %{status: "fractured", fractures: formatted})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/dead_code — Functions defined but never called
  # -------------------------------------------------------------------
  @skill %{
    intent: "Detect dead code (functions defined but never called)",
    endpoint: "GET /api/knowledge/dead_code",
    params: %{path: :required},
    returns: "JSON list of unused functions",
    category: "knowledge"
  }
  get "/dead_code" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_dead_code(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "dead_code failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "dead_code crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/cycles — Circular dependency detection
  # -------------------------------------------------------------------
  @skill %{
    intent: "Detect circular dependencies (strongly connected components)",
    endpoint: "GET /api/knowledge/cycles",
    params: %{path: :required},
    returns: "JSON list of cycle chains",
    category: "knowledge"
  }
  get "/cycles" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_cycles(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "cycles failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "cycles crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/god_modules — High complexity + centrality modules
  # -------------------------------------------------------------------
  @skill %{
    intent: "Detect god modules (high complexity + centrality + function count)",
    endpoint: "GET /api/knowledge/god_modules",
    params: %{path: :required},
    returns: "JSON list of god modules with scores",
    category: "knowledge"
  }
  get "/god_modules" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_god_modules(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "god_modules failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "god_modules crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/orphan_specs — @spec without matching function
  # -------------------------------------------------------------------
  @skill %{
    intent: "Detect orphan specs (@spec without matching function definition)",
    endpoint: "GET /api/knowledge/orphan_specs",
    params: %{path: :required},
    returns: "JSON list of orphan specs",
    category: "knowledge"
  }
  get "/orphan_specs" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_orphan_specs(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "orphan_specs failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "orphan_specs crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/fan_in_out — Dependency direction imbalance
  # -------------------------------------------------------------------
  @skill %{
    intent: "Analyze fan-in/fan-out (dependency direction imbalance)",
    endpoint: "GET /api/knowledge/fan_in_out",
    params: %{path: :required},
    returns: "JSON fan-in/fan-out analysis per module",
    category: "knowledge"
  }
  get "/fan_in_out" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_fan_in_out(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "fan_in_out failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "fan_in_out crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/coupling — Function-level dependency strength
  # -------------------------------------------------------------------
  @skill %{
    intent: "Analyze coupling (function-level dependency strength between module pairs)",
    endpoint: "GET /api/knowledge/coupling",
    params: %{path: :required},
    returns: "JSON coupling scores between module pairs",
    category: "knowledge"
  }
  get "/coupling" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.find_coupling(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "coupling failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "coupling crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/api_surface — Public vs private ratio
  # -------------------------------------------------------------------
  @skill %{
    intent: "Analyze API surface (public vs private function ratio per module)",
    endpoint: "GET /api/knowledge/api_surface",
    params: %{path: :required},
    returns: "JSON API surface analysis per module",
    category: "knowledge"
  }
  get "/api_surface" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_api_surface(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/change_risk — Composite refactoring priority
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get change risk score (composite refactoring priority per module)",
    endpoint: "GET /api/knowledge/change_risk",
    params: %{path: :required},
    returns: "JSON change risk scores ranked by priority",
    category: "knowledge"
  }
  get "/change_risk" do
    try do
      case resolve_project_path(conn) do
        nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
        project_path ->
          case Giulia.Knowledge.Store.change_risk_score(project_path) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> send_json(conn, 500, %{error: "change_risk failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "change_risk crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/path — Shortest path between two modules
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find shortest path between two modules in the dependency graph",
    endpoint: "GET /api/knowledge/path",
    params: %{path: :required, from: :required, to: :required},
    returns: "JSON path with hop count or 'no path found'",
    category: "knowledge"
  }
  get "/path" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        from = conn.query_params["from"]
        to = conn.query_params["to"]

        if from && to do
          case Giulia.Knowledge.Store.trace_path(project_path, from, to) do
            {:ok, :no_path} ->
              send_json(conn, 200, %{from: from, to: to, path: nil, message: "No path found"})

            {:ok, path} ->
              send_json(conn, 200, %{from: from, to: to, path: path, hops: length(path) - 1})

            {:error, {:not_found, vertex}} ->
              send_json(conn, 404, %{error: "Vertex not found in graph", vertex: vertex})
          end
        else
          send_json(conn, 400, %{error: "Missing required query params: from, to"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/logic_flow — Function-level Dijkstra path
  # -------------------------------------------------------------------
  @skill %{
    intent: "Trace function-level logic flow between two MFA vertices (Dijkstra)",
    endpoint: "GET /api/knowledge/logic_flow",
    params: %{path: :required, from: :required, to: :required},
    returns: "JSON step-by-step function call path",
    category: "knowledge"
  }
  get "/logic_flow" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        from = conn.query_params["from"]
        to = conn.query_params["to"]

        if from && to do
          case Giulia.Knowledge.Store.logic_flow(project_path, from, to) do
            {:ok, :no_path} ->
              send_json(conn, 200, %{from: from, to: to, steps: nil, hop_count: 0, message: "No path found"})

            {:ok, steps} ->
              send_json(conn, 200, %{from: from, to: to, steps: steps, hop_count: max(length(steps) - 1, 0)})

            {:error, {:not_found, vertex}} ->
              send_json(conn, 404, %{error: "MFA vertex not found in graph", vertex: vertex})
          end
        else
          send_json(conn, 400, %{error: "Missing required query params: from, to (MFA format: Module.func/arity)"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/style_oracle — Semantic search + quality gate
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find exemplar functions by concept with quality gate (@spec + @doc required)",
    endpoint: "GET /api/knowledge/style_oracle",
    params: %{path: :required, q: :required, top_k: :optional},
    returns: "JSON exemplar functions ranked by quality and relevance",
    category: "knowledge"
  }
  get "/style_oracle" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        query = conn.query_params["q"]

        if query do
          top_k = parse_int_param(conn.query_params["top_k"], 3)

          case Giulia.Knowledge.Store.style_oracle(project_path, query, top_k) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, "Semantic search unavailable" <> _} ->
              send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

            {:error, reason} ->
              send_json(conn, 500, %{error: inspect(reason)})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: q"})
        end
    end
  end

  # -------------------------------------------------------------------
  # POST /api/knowledge/pre_impact_check — Rename/remove risk analysis
  # -------------------------------------------------------------------
  @skill %{
    intent: "Analyze rename/remove risk with callers, risk score, phased migration plan",
    endpoint: "POST /api/knowledge/pre_impact_check",
    params: %{path: :required, module: :required, action: :required},
    returns: "JSON risk analysis with affected callers and migration steps",
    category: "knowledge"
  }
  post "/pre_impact_check" do
    path = conn.body_params["path"]
    module = conn.body_params["module"]
    action = conn.body_params["action"]

    if path && module && action do
      resolved_path = Giulia.Core.PathMapper.resolve_path(path)

      case Giulia.Knowledge.Store.pre_impact_check(resolved_path, conn.body_params) do
        {:ok, result} ->
          send_json(conn, 200, result)

        {:error, {:not_found, vertex}} ->
          send_json(conn, 404, %{error: "Vertex not found in graph", vertex: vertex})

        {:error, {:unknown_action, act}} ->
          send_json(conn, 400, %{error: "Unknown action: #{act}. Use: rename_function, remove_function, rename_module"})

        {:error, {:invalid_target, target}} ->
          send_json(conn, 400, %{error: "Invalid target format: #{target}. Use: func_name/arity"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required fields: path, module, action"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/heatmap — Composite module health scores
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get module heatmap (composite health scores 0-100, red/yellow/green zones)",
    endpoint: "GET /api/knowledge/heatmap",
    params: %{path: :required},
    returns: "JSON heatmap with per-module health scores",
    category: "knowledge"
  }
  get "/heatmap" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.heatmap(project_path) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/unprotected_hubs — Hubs with low spec/doc coverage
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find hub modules with low spec/doc coverage (unprotected hubs)",
    endpoint: "GET /api/knowledge/unprotected_hubs",
    params: %{path: :required, hub_threshold: :optional, spec_threshold: :optional},
    returns: "JSON list of unprotected hub modules with severity",
    category: "knowledge"
  }
  get "/unprotected_hubs" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        hub_threshold = parse_int_param(conn.query_params["hub_threshold"], 3)
        spec_threshold = parse_float_param(conn.query_params["spec_threshold"], 0.5)

        case Giulia.Knowledge.Store.find_unprotected_hubs(project_path,
               hub_threshold: hub_threshold, spec_threshold: spec_threshold) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/struct_lifecycle — Data flow tracing
  # -------------------------------------------------------------------
  @skill %{
    intent: "Trace struct lifecycle (data flow across modules)",
    endpoint: "GET /api/knowledge/struct_lifecycle",
    params: %{path: :required, struct: :optional},
    returns: "JSON struct lifecycle with creation, usage, and transformation points",
    category: "knowledge"
  }
  get "/struct_lifecycle" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        struct_filter = conn.query_params["struct"]

        case Giulia.Knowledge.Store.struct_lifecycle(project_path, struct_filter) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/duplicates — Semantic duplicate detection
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find semantic duplicates (redundant logic via embedding similarity)",
    endpoint: "GET /api/knowledge/duplicates",
    params: %{path: :required, threshold: :optional, max: :optional},
    returns: "JSON clusters of semantically similar functions",
    category: "knowledge"
  }
  get "/duplicates" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        threshold = parse_float_param(conn.query_params["threshold"], 0.85)
        max_clusters = parse_int_param(conn.query_params["max"], 20)

        case Giulia.Intelligence.SemanticIndex.find_duplicates(project_path,
               threshold: threshold, max: max_clusters) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, "Semantic search unavailable" <> _} ->
            send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

          {:error, reason} ->
            send_json(conn, 500, %{error: reason})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/audit — Unified audit (all 4 Principal Consultant features)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Run unified audit (unprotected hubs + struct lifecycle + duplicates + behaviour integrity)",
    endpoint: "GET /api/knowledge/audit",
    params: %{path: :required},
    returns: "JSON comprehensive audit with all 4 analysis results",
    category: "knowledge"
  }
  get "/audit" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        unprotected_hubs =
          case Giulia.Knowledge.Store.find_unprotected_hubs(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{modules: [], count: 0, severity_counts: %{red: 0, yellow: 0}}
          end

        struct_lifecycle =
          case Giulia.Knowledge.Store.struct_lifecycle(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{structs: [], count: 0}
          end

        semantic_duplicates =
          case Giulia.Intelligence.SemanticIndex.find_duplicates(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{clusters: [], count: 0, note: "Semantic search unavailable"}
          end

        behaviour_integrity =
          case Giulia.Knowledge.Store.check_all_behaviours(project_path) do
            {:ok, :consistent} ->
              %{status: "consistent", fractures: []}

            {:error, fractures} when is_map(fractures) ->
              formatted =
                Enum.map(fractures, fn {behaviour, impl_fractures} ->
                  %{
                    behaviour: behaviour,
                    fractures: Enum.map(impl_fractures, fn frac ->
                      format_fracture(frac)
                    end)
                  }
                end)

              %{status: "fractured", fractures: formatted}

            _ ->
              %{status: "unknown", fractures: []}
          end

        send_json(conn, 200, %{
          audit_version: "build_90",
          unprotected_hubs: unprotected_hubs,
          struct_lifecycle: struct_lifecycle,
          semantic_duplicates: semantic_duplicates,
          behaviour_integrity: behaviour_integrity
        })
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/topology — Full graph in Cytoscape.js format
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get full module dependency graph in Cytoscape.js-ready format (nodes + edges)",
    endpoint: "GET /api/knowledge/topology",
    params: %{path: :required},
    returns: "JSON with nodes (id, fan_in, fan_out, score, zone) and edges (source, target, label)",
    category: "knowledge"
  }
  get "/topology" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        # Get edges
        {:ok, edges} = Giulia.Knowledge.Store.all_dependencies(project_path)

        # Get heatmap for node scores
        {:ok, heatmap} = Giulia.Knowledge.Store.heatmap(project_path)
        heatmap_map = Map.new(heatmap.modules, fn m -> {m.module, m} end)

        # Get fan_in_out for centrality
        {:ok, fan_data} = Giulia.Knowledge.Store.find_fan_in_out(project_path)
        fan_map = Map.new(fan_data.modules, fn m -> {m.module, m} end)

        # Build Cytoscape nodes
        all_modules =
          (Enum.map(heatmap.modules, & &1.module) ++
           Enum.flat_map(edges, fn {s, t, _} -> [s, t] end))
          |> Enum.uniq()

        nodes = Enum.map(all_modules, fn mod ->
          h = Map.get(heatmap_map, mod, %{})
          f = Map.get(fan_map, mod, %{})
          breakdown = Map.get(h, :breakdown, %{})

          %{
            data: %{
              id: mod,
              label: mod |> String.split(".") |> Enum.slice(-2..-1) |> Enum.join("."),
              score: Map.get(h, :score, 0),
              zone: Map.get(h, :zone, "green"),
              fan_in: Map.get(f, :fan_in, 0),
              fan_out: Map.get(f, :fan_out, 0),
              complexity: Map.get(breakdown, :complexity, 0),
              has_test: Map.get(breakdown, :has_test, false)
            }
          }
        end)

        # Build Cytoscape edges
        cy_edges = Enum.map(edges, fn {source, target, label} ->
          %{data: %{source: source, target: target, label: to_string(label)}}
        end)

        send_json(conn, 200, %{
          nodes: nodes,
          edges: cy_edges,
          node_count: length(nodes),
          edge_count: length(cy_edges)
        })
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
