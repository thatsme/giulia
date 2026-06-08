defmodule Giulia.Daemon.Routers.Search do
  @moduledoc """
  Routes for code search (text and semantic).

  Forwarded from `/api/search` — paths here are relative to that prefix.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # GET /api/search — Direct text search (no LLM)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Search code by text pattern",
    endpoint: "GET /api/search",
    params: %{
      pattern: %{required: true, in: "query", doc: "Text pattern to search for (alias: q)"},
      path: %{required: false, in: "query", doc: "Absolute project path (defaults to CWD)"}
    },
    returns: "JSON search results",
    category: "search"
  }
  get "/" do
    pattern = conn.query_params["pattern"] || conn.query_params["q"]
    path = conn.query_params["path"]

    if pattern do
      resolved_path = if path, do: Giulia.Core.PathMapper.resolve_path(path), else: File.cwd!()
      sandbox = Giulia.Core.PathSandbox.new(resolved_path)
      opts = [sandbox: sandbox]

      case Giulia.Tools.SearchCode.execute(%{"pattern" => pattern}, opts) do
        {:ok, result} -> send_json(conn, 200, %{status: "ok", results: result})
        {:error, reason} -> send_json(conn, 400, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing 'pattern' or 'q' query parameter"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/search/semantic — Semantic search by concept
  # -------------------------------------------------------------------
  @skill %{
    intent: "Semantic search by concept (embedding-based)",
    endpoint: "GET /api/search/semantic",
    params: %{
      concept: %{required: true, in: "query", doc: "Concept to search for (alias: q)"},
      path: %{required: true, in: "query", doc: "Absolute project path"},
      top_k: %{required: false, in: "query", default: "5", doc: "Number of results to return"}
    },
    returns: "JSON with matching modules and functions ranked by relevance",
    category: "search"
  }
  get "/semantic" do
    # Resolution + readiness via the shared edge; coercion + canonical result
    # shape (modules/functions reshaped, count = total) live in Search.Facade,
    # shared with MCP. concept gate is in the facade (handles the q alias once).
    case Giulia.Daemon.Edge.resolve_ready(conn.query_params) do
      {:error, :missing_path} ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      {:not_ready, info} ->
        send_not_ready(conn, info)

      {:ok, project_path} ->
        case Giulia.Search.Facade.semantic(project_path, conn.query_params) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, :missing_concept} ->
            send_json(conn, 400, %{error: "Missing required query param: concept (or q)"})

          {:error, "Semantic search unavailable" <> _} ->
            send_json(conn, 503, %{
              error: "Semantic search unavailable. EmbeddingServing not loaded."
            })

          {:error, "No embeddings" <> _} ->
            send_json(conn, 404, %{
              error: "No embeddings for this project. Run POST /api/index/scan first."
            })

          {:error, reason} ->
            send_json(conn, 500, %{error: reason})
        end
    end
  end

  # -------------------------------------------------------------------
  # GET /api/search/semantic/status — Semantic search status
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check semantic search index status for a project",
    endpoint: "GET /api/search/semantic/status",
    params: %{path: %{required: true, in: "query", doc: "Absolute project path"}},
    returns: "JSON semantic index status",
    category: "search"
  }
  get "/semantic/status" do
    case resolve_project_path(conn) do
      nil ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      project_path ->
        status = Giulia.Intelligence.SemanticIndex.status(project_path)
        send_json(conn, 200, status)
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
