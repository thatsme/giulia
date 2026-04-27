defmodule Giulia.Daemon.Routers.Index do
  @moduledoc """
  Routes for the AST index (ETS-backed project metadata).

  Forwarded from `/api/index` — paths here are relative to that prefix.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # GET /api/index/modules — List all indexed modules
  # -------------------------------------------------------------------
  @skill %{
    intent: "List all indexed modules in a project",
    endpoint: "GET /api/index/modules",
    params: %{path: :required},
    returns: "JSON list of module names with count",
    category: "index"
  }
  get "/modules" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        modules = Giulia.Context.Store.Query.list_modules(project_path)
        send_json(conn, 200, %{modules: modules, count: length(modules)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/functions — List functions (optionally filtered by module)
  # -------------------------------------------------------------------
  @skill %{
    intent: "List functions in a project or module",
    endpoint: "GET /api/index/functions",
    params: %{path: :required, module: :optional},
    returns: "JSON list of function signatures with arities and line numbers",
    category: "index"
  }
  get "/functions" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        module_filter = conn.query_params["module"]
        functions = Giulia.Context.Store.Query.list_functions(project_path, module_filter)

        send_json(conn, 200, %{
          functions: functions,
          count: length(functions),
          module: module_filter
        })
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/module_details — Full module metadata
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Get full module details (file, moduledoc, functions, types, specs, callbacks, struct)",
    endpoint: "GET /api/index/module_details",
    params: %{path: :required, module: :required},
    returns: "JSON with module metadata including all API surface",
    category: "index"
  }
  get "/module_details" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        module = conn.query_params["module"]

        if module do
          details = Giulia.Context.Store.Formatter.module_details(project_path, module)
          send_json(conn, 200, %{module: module, details: details})
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/summary — Project shape overview
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get project summary (modules, functions, types, specs count)",
    endpoint: "GET /api/index/summary",
    params: %{path: :required},
    returns: "JSON project shape summary",
    category: "index"
  }
  get "/summary" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        summary = Giulia.Context.Store.Formatter.project_summary(project_path)
        send_json(conn, 200, %{summary: summary})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/status — Indexer status
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check indexer status (idle/scanning, file count, last scan time)",
    endpoint: "GET /api/index/status",
    params: %{path: "optional — project path for per-project status"},
    returns: "JSON indexer status",
    category: "index"
  }
  get "/status" do
    status =
      case resolve_project_path(conn) do
        nil -> Giulia.Context.Indexer.status()
        resolved -> Giulia.Context.Indexer.status(resolved)
      end

    # Enrich with cache status
    cache_status =
      case status.project_path do
        nil ->
          %{cache_status: "no_project"}

        project_path ->
          merkle_root =
            case Giulia.Persistence.Loader.cached_merkle_root(project_path) do
              {:ok, hash} -> String.slice(Base.encode16(hash, case: :lower), 0, 12)
              :not_cached -> nil
            end

          %{
            cache_status: if(merkle_root, do: "warm", else: "cold"),
            merkle_root: merkle_root
          }
      end

    send_json(conn, 200, Map.merge(status, cache_status))
  end

  # -------------------------------------------------------------------
  # POST /api/index/scan — Trigger project re-index
  # -------------------------------------------------------------------
  @skill %{
    intent: "Trigger a re-index scan for a project path",
    endpoint: "POST /api/index/scan",
    params: %{path: :required, force: :optional},
    returns:
      "JSON confirmation that scanning started. Pass `force: true` to bypass " <>
        "the L2 warm-cache and cold-extract from disk — needed after editing " <>
        "the extractor or graph builder.",
    category: "index"
  }
  post "/scan" do
    path = conn.body_params["path"]
    force? = truthy?(conn.body_params["force"])
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    cond do
      not is_binary(resolved_path) or resolved_path == "" ->
        send_json(conn, 422, %{
          error: "Missing or invalid :path",
          received: path
        })

      not File.dir?(resolved_path) ->
        send_json(conn, 422, %{
          error: "Path does not exist or is not a directory",
          path: resolved_path,
          received: path
        })

      not Giulia.Context.Indexer.valid_project_root?(resolved_path) ->
        # The Indexer refuses to scan directories without a project
        # marker anyway (see valid_project_root?/1). Return 422 up
        # front instead of 200 "scanning" followed by a silent cast
        # rejection.
        send_json(conn, 422, %{
          error: "No project root marker found",
          path: resolved_path,
          expected_markers: Giulia.Context.Indexer.project_markers()
        })

      true ->
        Giulia.Context.Indexer.scan(resolved_path, force: force?)
        send_json(conn, 200, %{status: "scanning", path: resolved_path, force: force?})
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  # -------------------------------------------------------------------
  # POST /api/index/enrichment — Ingest external-tool findings
  # -------------------------------------------------------------------
  @skill %{
    intent:
      "Ingest output from external Elixir tools (Credo, Dialyzer, ...) and " <>
        "attach findings to graph vertices for consumption by intelligence " <>
        "endpoints",
    endpoint: "POST /api/index/enrichment",
    params: %{tool: :required, project: :required, payload_path: :required},
    returns:
      "JSON {tool, ingested, written, replaced} — replaces all prior findings " <>
        "for this {tool, project}",
    category: "index"
  }
  post "/enrichment" do
    tool = conn.body_params["tool"]
    project = conn.body_params["project"]
    payload_path = conn.body_params["payload_path"]
    resolved_project = Giulia.Core.PathMapper.resolve_path(project)

    cond do
      not is_binary(tool) or tool == "" ->
        send_json(conn, 422, %{error: "Missing or invalid :tool"})

      not is_binary(resolved_project) or resolved_project == "" ->
        send_json(conn, 422, %{error: "Missing or invalid :project", received: project})

      not File.dir?(resolved_project) ->
        send_json(conn, 422, %{
          error: "Project path does not exist or is not a directory",
          path: resolved_project
        })

      not is_binary(payload_path) or payload_path == "" ->
        send_json(conn, 422, %{error: "Missing or invalid :payload_path"})

      Giulia.Context.ScanConfig.validate_enrichment_payload_path(
        payload_path,
        resolved_project
      ) != :ok ->
        send_json(conn, 422, %{
          error: "payload_path not under any allowed root",
          allowed_roots: Giulia.Context.ScanConfig.enrichment_payload_roots(),
          received: payload_path
        })

      not File.regular?(payload_path) ->
        send_json(conn, 422, %{
          error: "payload_path is not a regular file",
          received: payload_path
        })

      true ->
        case Giulia.Enrichment.Ingest.run(tool, resolved_project, payload_path) do
          {:ok, summary} -> send_json(conn, 200, summary)
          {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
        end
    end
  end

  # -------------------------------------------------------------------
  # POST /api/index/verify — Full Merkle verification
  # -------------------------------------------------------------------
  @skill %{
    intent: "Verify AST cache integrity via Merkle tree recomputation",
    endpoint: "POST /api/index/verify",
    params: %{path: :required},
    returns: "JSON verification result (ok or corrupted)",
    category: "index"
  }
  post "/verify" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Persistence.Store.get_db(resolved_path) do
      {:ok, db} ->
        case CubDB.get(db, {:merkle, :tree}) do
          nil ->
            send_json(conn, 200, %{status: "no_cache", verified: false})

          tree ->
            case Giulia.Persistence.Merkle.verify(tree) do
              :ok ->
                send_json(conn, 200, %{
                  status: "ok",
                  verified: true,
                  root:
                    String.slice(
                      Base.encode16(Giulia.Persistence.Merkle.root_hash(tree), case: :lower),
                      0,
                      12
                    ),
                  leaf_count: tree.leaf_count
                })

              {:error, :corrupted} ->
                send_json(conn, 200, %{
                  status: "corrupted",
                  verified: false,
                  leaf_count: tree.leaf_count
                })
            end
        end

      {:error, _reason} ->
        send_json(conn, 200, %{status: "no_cache", verified: false})
    end
  end

  # -------------------------------------------------------------------
  # POST /api/index/compact — Trigger CubDB compaction
  # -------------------------------------------------------------------
  @skill %{
    intent: "Trigger CubDB compaction to reclaim disk space",
    endpoint: "POST /api/index/compact",
    params: %{path: :required},
    returns: "JSON confirmation of compaction trigger",
    category: "index"
  }
  post "/compact" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Persistence.Store.compact(resolved_path) do
      :ok -> send_json(conn, 200, %{status: "compacting", path: resolved_path})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/complexity — Per-function cognitive complexity ranking
  # -------------------------------------------------------------------
  @skill %{
    intent: "Rank functions by cognitive complexity (Sonar-style, nesting-aware)",
    endpoint: "GET /api/index/complexity",
    params: %{path: :required, module: :optional, min: :optional, limit: :optional},
    returns: "JSON list of functions sorted by complexity descending",
    category: "index"
  }
  get "/complexity" do
    case resolve_and_check_ready(conn) do
      {:halt, conn} ->
        conn

      {:ok, conn, project_path} ->
        module_filter = conn.query_params["module"]
        min_complexity = parse_int(conn.query_params["min"], 0)
        result_limit = parse_int(conn.query_params["limit"], 50)

        functions =
          Giulia.Context.Store.Query.list_functions(project_path, module_filter)
          |> Enum.filter(fn f -> f.complexity >= min_complexity end)
          |> Enum.sort_by(& &1.complexity, :desc)
          |> Enum.take(result_limit)

        send_json(conn, 200, %{
          functions: functions,
          count: length(functions),
          module: module_filter,
          min_complexity: min_complexity
        })
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end
end
