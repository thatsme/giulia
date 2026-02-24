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
    params: %{pattern: :required, path: :optional},
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
    params: %{concept: :required, path: :required, top_k: :optional},
    returns: "JSON with matching modules and functions ranked by relevance",
    category: "search"
  }
  get "/semantic" do
    concept = conn.query_params["concept"] || conn.query_params["q"]

    if concept do
      case resolve_project_path(conn) do
        nil ->
          send_json(conn, 400, %{error: "Missing required query param: path"})

        project_path ->
          top_k = parse_int_param(conn.query_params["top_k"], 5)

          case Giulia.Intelligence.SemanticIndex.search(project_path, concept, top_k) do
            {:ok, %{modules: modules, functions: functions}} ->
              mod_json =
                Enum.map(modules, fn m ->
                  %{
                    module: m.id,
                    score: m.score,
                    moduledoc: m.metadata[:moduledoc] || ""
                  }
                end)

              func_json =
                Enum.map(functions, fn f ->
                  %{
                    module: f.metadata.module,
                    function: f.metadata.function,
                    arity: f.metadata.arity,
                    score: f.score,
                    file: f.metadata.file,
                    line: f.metadata.line
                  }
                end)

              send_json(conn, 200, %{
                concept: concept,
                modules: mod_json,
                functions: func_json,
                count: length(func_json)
              })

            {:error, "Semantic search unavailable" <> _} ->
              send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

            {:error, "No embeddings" <> _} ->
              send_json(conn, 404, %{error: "No embeddings for this project. Run POST /api/index/scan first."})

            {:error, reason} ->
              send_json(conn, 500, %{error: reason})
          end
      end
    else
      send_json(conn, 400, %{error: "Missing required query param: concept (or q)"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/search/semantic/status — Semantic search status
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check semantic search index status for a project",
    endpoint: "GET /api/search/semantic/status",
    params: %{path: :required},
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
