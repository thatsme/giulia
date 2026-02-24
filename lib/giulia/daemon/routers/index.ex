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
    send_json(conn, 200, status)
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

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
