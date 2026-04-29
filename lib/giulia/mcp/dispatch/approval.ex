defmodule Giulia.MCP.Dispatch.Approval do
  @moduledoc """
  MCP dispatch handlers for the `approval_*` tool family.

  Maps `approval_respond` / `approval_get_pending` MCP tool calls to
  `Giulia.Inference.Approval` business logic.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Inference.Approval

  @spec respond(map()) :: {:ok, map()} | {:error, String.t()}
  def respond(args) do
    with {:ok, approval_id} <- require_param(args, "approval_id") do
      approved = args["approved"] == true or args["approved"] == "true"

      case Approval.respond(approval_id, approved) do
        :ok ->
          {:ok, %{status: "responded", approval_id: approval_id, approved: approved}}

        {:error, :not_found} ->
          {:error, "Approval request not found: #{approval_id}"}
      end
    end
  end

  @spec get_pending(map()) :: {:ok, map()} | {:error, String.t()}
  def get_pending(args) do
    with {:ok, approval_id} <- require_param(args, "approval_id") do
      case Approval.get_pending(approval_id) do
        {:ok, request} -> {:ok, request}
        {:error, :not_found} -> {:error, "Approval request not found: #{approval_id}"}
      end
    end
  end
end
