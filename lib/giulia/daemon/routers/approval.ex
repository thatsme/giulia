defmodule Giulia.Daemon.Routers.Approval do
  @moduledoc """
  Routes for the approval consent gate.

  Forwarded from `/api/approval` — paths here are relative to that prefix.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # POST /api/approval/:approval_id — Respond to an approval request
  # -------------------------------------------------------------------
  @skill %{
    intent: "Respond to an approval request",
    endpoint: "POST /api/approval/:approval_id",
    params: %{approval_id: :required, approved: :required},
    returns: "JSON confirmation with approval_id and approved flag",
    category: "approval"
  }
  post "/:approval_id" do
    approval_id = conn.path_params["approval_id"]
    approved = conn.body_params["approved"] == true

    Giulia.Inference.Approval.respond(approval_id, approved)
    send_json(conn, 200, %{status: "ok", approval_id: approval_id, approved: approved})
  end

  # -------------------------------------------------------------------
  # GET /api/approval/:approval_id — Get pending approval request info
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get pending approval request info",
    endpoint: "GET /api/approval/:approval_id",
    params: %{approval_id: :required},
    returns: "JSON approval request details or 404",
    category: "approval"
  }
  get "/:approval_id" do
    approval_id = conn.path_params["approval_id"]

    case Giulia.Inference.Approval.get_pending(approval_id) do
      {:ok, info} ->
        send_json(conn, 200, info)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "Approval request not found or already resolved"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
