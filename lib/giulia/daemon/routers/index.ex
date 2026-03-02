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
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        modules = Giulia.Context.Store.list_modules(project_path)
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
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module_filter = conn.query_params["module"]
        functions = Giulia.Context.Store.list_functions(project_path, module_filter)
        send_json(conn, 200, %{functions: functions, count: length(functions), module: module_filter})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/module_details — Full module metadata
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get full module details (file, moduledoc, functions, types, specs, callbacks, struct)",
    endpoint: "GET /api/index/module_details",
    params: %{path: :required, module: :required},
    returns: "JSON with module metadata including all API surface",
    category: "index"
  }
  get "/module_details" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          details = Giulia.Context.Store.module_details(project_path, module)
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
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        summary = Giulia.Context.Store.project_summary(project_path)
        send_json(conn, 200, %{summary: summary})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/index/status — Indexer status
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check indexer status (idle/scanning, file count, last scan time)",
    endpoint: "GET /api/index/status",
    params: %{},
    returns: "JSON indexer status",
    category: "index"
  }
  get "/status" do
    status = Giulia.Context.Indexer.status()

    # Enrich with cache status
    cache_status =
      case status.project_path do
        nil ->
          %{cache_status: "no_project"}

        project_path ->
          merkle_root =
            case Giulia.Persistence.Loader.cached_merkle_root(project_path) do
              {:ok, hash} -> Base.encode16(hash, case: :lower) |> String.slice(0, 12)
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
    params: %{path: :required},
    returns: "JSON confirmation that scanning started",
    category: "index"
  }
  post "/scan" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    Giulia.Context.Indexer.scan(resolved_path)
    send_json(conn, 200, %{status: "scanning", path: resolved_path})
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
                  root: Base.encode16(Giulia.Persistence.Merkle.root_hash(tree), case: :lower) |> String.slice(0, 12),
                  leaf_count: tree.leaf_count
                })

              {:error, :corrupted} ->
                send_json(conn, 200, %{status: "corrupted", verified: false, leaf_count: tree.leaf_count})
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

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
