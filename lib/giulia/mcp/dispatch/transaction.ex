defmodule Giulia.MCP.Dispatch.Transaction do
  @moduledoc """
  MCP dispatch handlers for the `transaction_*` tool family.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Core.{ContextManager, PathMapper, ProjectContext}

  @spec enable(map()) :: {:ok, map()} | {:error, String.t()}
  def enable(args) do
    with {:ok, path} <- require_path(args) do
      case ContextManager.get_context(path) do
        {:ok, pid} ->
          new_mode = ProjectContext.toggle_transaction_preference(pid)
          {:ok, %{transaction_mode: new_mode, path: path}}

        {:needs_init, _} ->
          {:error, "Project not initialized. Run index/scan first."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @spec staged(map()) :: {:ok, map()} | {:error, String.t()}
  def staged(args) do
    path = if args["path"], do: PathMapper.resolve_path(args["path"]), else: nil

    if path do
      case ContextManager.get_context(path) do
        {:ok, pid} ->
          pref = ProjectContext.transaction_preference(pid)
          {:ok, %{transaction_mode: pref, staged_files: [], path: path}}

        {:needs_init, _} ->
          {:ok, %{transaction_mode: false, staged_files: [], path: path}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:ok, %{transaction_mode: false, staged_files: []}}
    end
  end

  @spec rollback(map()) :: {:ok, map()} | {:error, String.t()}
  def rollback(args) do
    with {:ok, path} <- require_path(args) do
      case ContextManager.get_context(path) do
        {:ok, pid} ->
          pref = ProjectContext.transaction_preference(pid)

          if pref do
            ProjectContext.toggle_transaction_preference(pid)
            {:ok, %{status: "reset", transaction_mode: false, path: path}}
          else
            {:ok, %{status: "already_off", transaction_mode: false, path: path}}
          end

        {:needs_init, _} ->
          {:error, "Project not initialized."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end
end
