defmodule Giulia.Daemon.Routers.Intelligence do
  @moduledoc """
  Routes for intelligence features: briefing, preflight, architect brief, plan validation.

  Forwarded from multiple prefixes due to inconsistent original paths:
  - `/api/intelligence` → GET /briefing
  - `/api/briefing`     → POST /preflight
  - `/api/brief`        → GET /architect
  - `/api/plan`         → POST /validate
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # GET /api/intelligence/briefing — Surgical Briefing (Layer 1+2)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Build a surgical briefing for a prompt (semantic + graph pre-processing)",
    endpoint: "GET /api/intelligence/briefing",
    params: %{path: :required, prompt: :required},
    returns: "JSON briefing with relevant modules and context",
    category: "intelligence"
  }
  get "/briefing" do
    concept = conn.query_params["prompt"] || conn.query_params["q"]

    if concept do
      case resolve_project_path(conn) do
        nil ->
          send_json(conn, 400, %{error: "Missing required query param: path"})

        project_path ->
          case Giulia.Intelligence.SurgicalBriefing.build(concept, project_path) do
            {:ok, briefing} ->
              send_json(conn, 200, %{status: "ok", briefing: briefing})

            :skip ->
              send_json(conn, 200, %{
                status: "skipped",
                briefing: nil,
                message: "Briefing skipped (unavailable, no embeddings, or below relevance threshold)"
              })
          end
      end
    else
      send_json(conn, 400, %{error: "Missing required query param: prompt (or q)"})
    end
  end

  # -------------------------------------------------------------------
  # POST /api/briefing/preflight — Preflight Contract Checklist (Layer 3)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Run preflight contract checklist for a prompt",
    endpoint: "POST /api/briefing/preflight",
    params: %{prompt: :required, path: :required, top_k: :optional, depth: :optional},
    returns: "JSON structured contract analysis with 6 sections per module",
    category: "intelligence"
  }
  post "/preflight" do
    prompt = conn.body_params["prompt"]
    path = conn.body_params["path"]

    if prompt && path do
      resolved_path = Giulia.Core.PathMapper.resolve_path(path)
      top_k = parse_int_param(conn.body_params["top_k"], 5)
      depth = parse_int_param(conn.body_params["depth"], 2)

      case Giulia.Intelligence.Preflight.run(prompt, resolved_path, top_k: top_k, depth: depth) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required fields: prompt and path"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/brief/architect — Architect Brief (Build 91)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Single-call project briefing (topology, health, constitution)",
    endpoint: "GET /api/brief/architect",
    params: %{path: :required},
    returns: "JSON architect brief with project shape, heatmap, and constitution summary",
    category: "intelligence"
  }
  get "/architect" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Intelligence.ArchitectBrief.build(project_path) do
          {:ok, brief} -> send_json(conn, 200, brief)
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # -------------------------------------------------------------------
  # POST /api/plan/validate — Plan Validation Gate (Build 93)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Validate a proposed plan against the Knowledge Graph",
    endpoint: "POST /api/plan/validate",
    params: %{path: :required, plan: :required},
    returns: "JSON validation result with risk assessment",
    category: "intelligence"
  }
  post "/validate" do
    path = conn.body_params["path"]
    plan = conn.body_params["plan"]

    if path && plan do
      resolved_path = Giulia.Core.PathMapper.resolve_path(path)

      case Giulia.Intelligence.PlanValidator.validate(plan, resolved_path) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required fields: path and plan"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
