defmodule Giulia.Daemon.Routers.Transaction do
  @moduledoc """
  Routes for the Transactional Exoskeleton.

  Forwarded from `/api/transaction` — paths here are relative to that prefix.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # POST /api/transaction/enable — Toggle transaction mode
  # -------------------------------------------------------------------
  @skill %{
    intent: "Toggle transaction mode for a project",
    endpoint: "POST /api/transaction/enable",
    params: %{path: :required},
    returns: "JSON with new transaction_mode status",
    category: "transaction"
  }
  post "/enable" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        new_mode = Giulia.Core.ProjectContext.toggle_transaction_preference(context_pid)
        status = if new_mode, do: "enabled", else: "disabled"
        send_json(conn, 200, %{status: status, transaction_mode: new_mode})

      _ ->
        send_json(conn, 400, %{error: "No active project context"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/transaction/staged — View transaction preference
  # -------------------------------------------------------------------
  @skill %{
    intent: "View transaction staging status",
    endpoint: "GET /api/transaction/staged",
    params: %{path: :optional},
    returns: "JSON with transaction_mode and staged_files (always empty — staging is per-inference)",
    category: "transaction"
  }
  get "/staged" do
    path = conn.query_params["path"]
    resolved_path = if path, do: Giulia.Core.PathMapper.resolve_path(path), else: nil

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        pref = Giulia.Core.ProjectContext.transaction_preference(context_pid)

        send_json(conn, 200, %{
          transaction_mode: pref,
          staged_files: [],
          count: 0,
          note: "Staged files exist only during active inference sessions"
        })

      _ ->
        send_json(conn, 200, %{transaction_mode: false, staged_files: [], count: 0})
    end
  end

  # -------------------------------------------------------------------
  # POST /api/transaction/rollback — Reset transaction preference
  # -------------------------------------------------------------------
  @skill %{
    intent: "Reset transaction mode (disable)",
    endpoint: "POST /api/transaction/rollback",
    params: %{path: :required},
    returns: "JSON confirmation of reset",
    category: "transaction"
  }
  post "/rollback" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        pref = Giulia.Core.ProjectContext.transaction_preference(context_pid)
        if pref, do: Giulia.Core.ProjectContext.toggle_transaction_preference(context_pid)
        send_json(conn, 200, %{status: "reset", transaction_mode: false})

      _ ->
        send_json(conn, 400, %{error: "No active project context"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
