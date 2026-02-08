defmodule Giulia.Tools.GetStagedFiles do
  @moduledoc """
  Pseudo-tool to inspect the current staging buffer during transaction mode.

  Returns a list of all files currently staged in memory, with byte sizes.
  The Orchestrator intercepts this call and returns the staging buffer contents
  directly — no disk access needed.
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "get_staged_files"

  @impl true
  def description,
    do: "List all files currently staged in the transaction buffer (not yet written to disk)"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  # This should never be called directly — Orchestrator intercepts it
  @impl true
  def execute(_params, _opts), do: {:ok, "get_staged_files intercepted"}
end
