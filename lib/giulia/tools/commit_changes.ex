defmodule Giulia.Tools.CommitChanges do
  @moduledoc """
  Pseudo-tool for atomically committing staged changes to disk.

  When transaction_mode is active, write tools (write_file, edit_file,
  patch_function, write_function) buffer changes in memory instead of
  writing to disk. This tool flushes the staging buffer atomically:

  1. Write all staged files to disk
  2. Run mix compile to verify
  3. Run auto-regression tests for modified modules
  4. On failure: rollback ALL changes and restore originals

  The real logic lives in the Orchestrator — this tool exists so the
  LLM can "call" it and the Orchestrator intercepts it.
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "commit_changes"

  @impl true
  def description, do: "Atomically flush all staged changes to disk, compile, test, and rollback on failure"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        message: %{
          type: "string",
          description: "Optional commit message describing the changes"
        }
      },
      required: []
    }
  end

  # This should never be called directly — Orchestrator intercepts it
  def execute(%{"message" => message}, _opts), do: {:ok, "commit_changes intercepted: #{message}"}
  def execute(_params, _opts), do: {:ok, "commit_changes intercepted"}
end
