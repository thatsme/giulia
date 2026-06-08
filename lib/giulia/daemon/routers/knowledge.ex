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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON graph stats with top hub modules",
    category: "knowledge"
  }
  get "/stats" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        stats = Giulia.Knowledge.Store.stats(project_path)

        hubs =
          Enum.map(stats.hubs || [], fn {name, degree} -> %{module: name, degree: degree} end)

        send_json(conn, 200, %{stats | hubs: hubs})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/dependents — Who depends on module X
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find all modules that depend on a given module (downstream blast radius)",
    endpoint: "GET /api/knowledge/dependents",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      module: %{required: true, in: "query", doc: "Module name (e.g. Giulia.Tools.Registry)"}
    },
    returns: "JSON list of dependent modules with count",
    category: "knowledge"
  }
  get "/dependents" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      module: %{required: true, in: "query", doc: "Module name (e.g. Giulia.Tools.Registry)"}
    },
    returns: "JSON list of dependency modules with count",
    category: "knowledge"
  }
  get "/dependencies" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      module: %{required: true, in: "query", doc: "Module name (e.g. Giulia.Tools.Registry)"}
    },
    returns: "JSON centrality data with in/out degree and dependents list",
    category: "knowledge"
  }
  get "/centrality" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      module: %{required: true, in: "query", doc: "Module name (e.g. Giulia.Tools.Registry)"},
      depth: %{
        required: false,
        in: "query",
        default: "2",
        doc: "Traversal depth (upstream+downstream)"
      }
    },
    returns: "JSON impact map with upstream, downstream, and function-level edges",
    category: "knowledge"
  }
  get "/impact" do
    # Resolution + readiness via the shared facade step (single source, also used
    # by MCP). REST renders the readiness payload as 409 + hint; module
    # required-ness stays at the REST edge (400).
    case Giulia.Daemon.Edge.resolve_ready(conn.query_params) do
      {:error, :missing_path} ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      {:not_ready, info} ->
        send_not_ready(conn, info)

      {:ok, project_path} ->
        if conn.query_params["module"] do
          case Giulia.Knowledge.Facade.impact(project_path, conn.query_params) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, {:not_found, info}} ->
              send_json(conn, 404, Map.put(info, :error, "Module not found in graph"))
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON with consistent/fractured status and fracture details",
    category: "knowledge"
  }
  get "/integrity" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        {:ok, report} = Giulia.Knowledge.Store.integrity_report(project_path)
        send_json(conn, 200, report)
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/dead_code — Functions defined but never called
  # -------------------------------------------------------------------
  @skill %{
    intent: "Detect dead code (functions defined but never called)",
    endpoint: "GET /api/knowledge/dead_code",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      relevance: %{
        required: false,
        in: "query",
        values: ~w(high medium all),
        default: "all",
        doc:
          "high -> :genuine only; medium -> :genuine + :uncategorized (= :actionable); all/absent -> unfiltered"
      }
    },
    returns: "JSON list of unused functions",
    notes:
      "Excludes OTP callbacks, behaviour implementations, framework entry points. " <>
        ":enrichments appear per entry only when external-tool findings are ingested (POST /api/index/enrichment).",
    category: "knowledge"
  }
  get "/dead_code" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          opts = [relevance: conn.query_params["relevance"]]

          case Giulia.Knowledge.Store.find_dead_code(project_path, opts) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "dead_code failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON list of cycle chains",
    category: "knowledge"
  }
  get "/cycles" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.find_cycles(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "cycles failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON list of god modules with scores",
    category: "knowledge"
  }
  get "/god_modules" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.find_god_modules(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "god_modules failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON list of orphan specs",
    category: "knowledge"
  }
  get "/orphan_specs" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.find_orphan_specs(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "orphan_specs failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON fan-in/fan-out analysis per module",
    category: "knowledge"
  }
  get "/fan_in_out" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.find_fan_in_out(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "fan_in_out failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON coupling scores between module pairs",
    category: "knowledge"
  }
  get "/coupling" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.find_coupling(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "coupling failed", detail: inspect(reason)})
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON API surface analysis per module",
    category: "knowledge"
  }
  get "/api_surface" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON change risk scores ranked by priority",
    category: "knowledge"
  }
  get "/change_risk" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          case Giulia.Knowledge.Store.change_risk_score(project_path) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, reason} ->
              send_json(conn, 500, %{error: "change_risk failed", detail: inspect(reason)})
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      from: %{required: true, in: "query", doc: "Source module name"},
      to: %{required: true, in: "query", doc: "Target module name"}
    },
    returns: "JSON path with hop count or 'no path found'",
    category: "knowledge"
  }
  get "/path" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      from: %{required: true, in: "query", format: "Module.func/arity", doc: "Source MFA vertex"},
      to: %{required: true, in: "query", format: "Module.func/arity", doc: "Target MFA vertex"}
    },
    returns: "JSON step-by-step function call path",
    category: "knowledge"
  }
  get "/logic_flow" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        from = conn.query_params["from"]
        to = conn.query_params["to"]

        if from && to do
          case Giulia.Knowledge.Store.logic_flow(project_path, from, to) do
            {:ok, :no_path} ->
              send_json(conn, 200, %{
                from: from,
                to: to,
                steps: nil,
                hop_count: 0,
                message: "No path found"
              })

            {:ok, steps} ->
              send_json(conn, 200, %{
                from: from,
                to: to,
                steps: steps,
                hop_count: max(length(steps) - 1, 0)
              })

            {:error, {:not_found, vertex}} ->
              send_json(conn, 404, %{error: "MFA vertex not found in graph", vertex: vertex})
          end
        else
          send_json(conn, 400, %{
            error: "Missing required query params: from, to (MFA format: Module.func/arity)"
          })
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/style_oracle — Semantic search + quality gate
  # -------------------------------------------------------------------
  @skill %{
    intent: "Find exemplar functions by concept with quality gate (@spec + @doc required)",
    endpoint: "GET /api/knowledge/style_oracle",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      q: %{required: true, in: "query", doc: "Concept to find exemplars for"},
      top_k: %{required: false, in: "query", default: "3", doc: "Number of exemplars"}
    },
    returns: "JSON exemplar functions ranked by quality and relevance",
    category: "knowledge"
  }
  get "/style_oracle" do
    case Giulia.Daemon.Edge.resolve_ready(conn.query_params) do
      {:error, :missing_path} ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      {:not_ready, info} ->
        send_not_ready(conn, info)

      {:ok, project_path} ->
        if conn.query_params["q"] do
          case Giulia.Knowledge.Facade.style_oracle(project_path, conn.query_params) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, "Semantic search unavailable" <> _} ->
              send_json(conn, 503, %{
                error: "Semantic search unavailable. EmbeddingServing not loaded."
              })

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
    params: %{
      path: %{required: true, in: "body", doc: "Absolute project path"},
      module: %{required: true, in: "body", doc: "Module the target lives in"},
      action: %{
        required: true,
        in: "body",
        values: ~w(rename_function remove_function rename_module),
        doc: "Operation to assess"
      },
      target: %{
        required: false,
        in: "body",
        format: "func/arity",
        doc: "Target function (required for function-level actions)"
      },
      new_name: %{required: false, in: "body", doc: "New name (required for rename actions)"}
    },
    returns: "JSON risk analysis with affected callers and migration steps",
    notes:
      "404 if the vertex is not in the graph; 400 on unknown action or invalid target format. " <>
        "When external-tool enrichments are ingested, affected_callers carry :enrichments.",
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
          # Stamp the result with the schema version of the extractor +
          # graph-builder that produced it. Agents calling this endpoint
          # in automated refactor-safety loops can compare against a
          # known-complete version (v8, the graph-completeness fix) to
          # decide whether the caller set is trustworthy. Pre-v8 answers
          # undercounted callers for modules reached through aliased
          # calls — see CHANGELOG.md v0.2.2.
          result_with_version =
            Map.put(
              result,
              :schema_version,
              Giulia.Persistence.Store.schema_version()
            )

          send_json(conn, 200, result_with_version)

        {:error, {:not_found, vertex}} ->
          send_json(conn, 404, %{error: "Vertex not found in graph", vertex: vertex})

        {:error, {:unknown_action, act}} ->
          send_json(conn, 400, %{
            error: "Unknown action: #{act}. Use: rename_function, remove_function, rename_module"
          })

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
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON heatmap with per-module health scores",
    category: "knowledge"
  }
  get "/heatmap" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      hub_threshold: %{
        required: false,
        in: "query",
        default: "3",
        doc: "Min in-degree to count as a hub"
      },
      spec_threshold: %{
        required: false,
        in: "query",
        default: "0.5",
        doc: "Spec-coverage floor (0.0-1.0)"
      }
    },
    returns: "JSON list of unprotected hub modules with severity",
    category: "knowledge"
  }
  get "/unprotected_hubs" do
    case Giulia.Daemon.Edge.resolve_ready(conn.query_params) do
      {:error, :missing_path} ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      {:not_ready, info} ->
        send_not_ready(conn, info)

      {:ok, project_path} ->
        case Giulia.Knowledge.Facade.unprotected_hubs(project_path, conn.query_params) do
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      struct: %{required: false, in: "query", format: "Module.Name", doc: "Filter to one struct"}
    },
    returns: "JSON struct lifecycle with creation, usage, and transformation points",
    category: "knowledge"
  }
  get "/struct_lifecycle" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
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
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      threshold: %{
        required: false,
        in: "query",
        default: "0.85",
        doc: "Cosine similarity floor (0.0-1.0)"
      },
      max: %{required: false, in: "query", default: "20", doc: "Max clusters returned"},
      relevance: %{
        required: false,
        in: "query",
        values: ~w(high medium all),
        doc:
          "Shorthand that TIGHTENS threshold: high -> 0.95, medium -> 0.90. A user-supplied threshold higher than the bucket wins -- relevance only tightens, never loosens."
      }
    },
    returns: "JSON clusters of semantically similar functions",
    notes:
      "Requires EmbeddingServing; returns [] if unavailable OR not loaded for this role (the monitor skips it by design -- query the worker on :4000).",
    category: "knowledge"
  }
  get "/duplicates" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        threshold = parse_float_param(conn.query_params["threshold"], 0.85)
        max_clusters = parse_int_param(conn.query_params["max"], 20)

        case Giulia.Intelligence.SemanticIndex.find_duplicates(project_path,
               threshold: threshold,
               max: max_clusters,
               relevance: conn.query_params["relevance"]
             ) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, "Semantic search unavailable" <> _} ->
            send_json(conn, 503, %{
              error: "Semantic search unavailable. EmbeddingServing not loaded."
            })

          {:error, reason} ->
            send_json(conn, 500, %{error: reason})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/audit — Unified audit (all 4 Principal Consultant features)
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Run unified audit (unprotected hubs + struct lifecycle + duplicates + behaviour integrity)",
    endpoint: "GET /api/knowledge/audit",
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON comprehensive audit with all 4 analysis results",
    category: "knowledge"
  }
  get "/audit" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        {:ok, audit} = Giulia.Knowledge.Store.audit(project_path)
        send_json(conn, 200, audit)
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/topology — Full graph in Cytoscape.js format
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get full module dependency graph in Cytoscape.js-ready format (nodes + edges)",
    endpoint: "GET /api/knowledge/topology",
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns:
      "JSON with nodes (id, fan_in, fan_out, score, zone) and edges (source, target, label)",
    category: "knowledge"
  }
  get "/topology" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        {:ok, view} = Giulia.Knowledge.Store.topology_view(project_path)
        send_json(conn, 200, view)
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/conventions — Coding convention violations
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Detect coding convention violations (error handling, OTP, atoms, pipes, docs) with optional per-rule per-module suppression",
    endpoint: "GET /api/knowledge/conventions",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      module: %{required: false, in: "query", doc: "Filter to one module"},
      suppress: %{
        required: false,
        in: "query",
        format: "rule:Mod1,Mod2;rule2:Mod3",
        doc: "Skip specific rules for specific modules"
      },
      relevance: %{
        required: false,
        in: "query",
        values: ~w(high medium all),
        default: "all",
        doc: "high -> error only; medium -> error + warning; all -> unfiltered"
      }
    },
    returns: "JSON violations grouped by severity, category, and file with convention references",
    category: "knowledge"
  }
  get "/conventions" do
    try do
      case resolve_and_check_ready(conn) do
        {:halt, conn} ->
          conn

        {:ok, conn, project_path} ->
          module_filter = conn.query_params["module"]
          suppress = parse_suppress(conn.query_params["suppress"])

          opts = [suppress: suppress, relevance: conn.query_params["relevance"]]
          opts = if module_filter, do: Keyword.put(opts, :module, module_filter), else: opts

          case Giulia.Knowledge.Store.find_conventions(project_path, opts) do
            {:ok, data} ->
              send_json(conn, 200, data)

            {:error, reason} ->
              send_json(conn, 500, %{error: "conventions failed", detail: inspect(reason)})
          end
      end
    rescue
      e -> send_json(conn, 500, %{error: "conventions crashed", detail: Exception.message(e)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/verify_l2 — Round-trip checks L1 ETS ↔ L2 CubDB
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Verify L1 (ETS) matches L2 (CubDB) for the graph, AST, and/or metrics payloads after serialization round-trip. Parity + stratified sample identity per payload.",
    endpoint: "GET /api/knowledge/verify_l2",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      check: %{
        required: false,
        in: "query",
        values: ~w(graph ast metrics all),
        default: "all",
        doc: "Which payload to verify"
      },
      sample_per_label: %{
        required: false,
        in: "query",
        default: "10",
        doc: "Sample size per payload"
      }
    },
    returns:
      "JSON report with per-payload checks and an overall pass/fail. `check` ∈ graph | ast | metrics | all (default all).",
    category: "knowledge"
  }
  get "/verify_l2" do
    case resolve_project_path(conn) do
      nil ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      project_path ->
        sample = parse_int(conn.query_params["sample_per_label"], 10)
        check = conn.query_params["check"] || "all"

        {:ok, report} =
          Giulia.Persistence.Verifier.verify_l2(project_path,
            sample_per_label: sample,
            check: check
          )

        send_json(conn, 200, report)
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  # -------------------------------------------------------------------
  # GET /api/knowledge/verify_l3 — Sample-identity check L1→L3 CALLS
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Verify function-level :calls edges round-trip from L1 (libgraph) to L3 (ArcadeDB). Stratified sample across resolution-path buckets; surfaces silent mismatches between stores.",
    endpoint: "GET /api/knowledge/verify_l3",
    params: %{
      path: %{required: true, in: "query", doc: "Absolute project path"},
      sample_per_bucket: %{
        required: false,
        in: "query",
        default: "10",
        doc: "MFA sample size per resolution-path bucket"
      }
    },
    notes: "Requires ArcadeDB (L3). overall: pass on a healthy system regardless of prior scans.",
    returns: "JSON report with per-bucket {ok, missing, errors} counts and overall pass/fail",
    category: "knowledge"
  }
  get "/verify_l3" do
    case resolve_project_path(conn) do
      nil ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      project_path ->
        sample_per_bucket =
          case conn.query_params["sample_per_bucket"] do
            nil ->
              10

            s ->
              case Integer.parse(s) do
                {n, _} -> n
                :error -> 10
              end
          end

        case Giulia.Storage.Arcade.Verifier.verify(project_path,
               sample_per_bucket: sample_per_bucket
             ) do
          {:ok, report} ->
            send_json(conn, 200, report)

          {:error, reason} ->
            send_json(conn, 500, %{error: "verify failed", detail: inspect(reason)})
        end
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
