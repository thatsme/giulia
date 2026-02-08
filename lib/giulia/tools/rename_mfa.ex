defmodule Giulia.Tools.RenameMFA do
  @moduledoc """
  Automated MFA (Module.Function/Arity) rename across the entire codebase.

  The LLM identifies the intent to rename. Elixir handles the execution perfectly.

  This is a pseudo-tool — the Orchestrator intercepts the call and uses:
  1. Knowledge Graph to discover all callers and implementers
  2. Context.Store to map module names to file paths
  3. Sourceror to find exact function definitions and calls in the AST
  4. Staging buffer to stage all changes atomically

  The model never does string-matching refactors. This tool does.
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "rename_mfa"

  @impl true
  def description do
    "Rename a function across the entire codebase using AST analysis. " <>
      "Finds all definitions (def/defp), remote calls (Module.func), local calls, " <>
      "@callback declarations, and @impl functions. " <>
      "All changes are staged atomically — use commit_changes to flush."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        module: %{
          type: "string",
          description: "The fully-qualified module name where the function is defined (e.g. 'Giulia.Tools.Registry')"
        },
        old_name: %{
          type: "string",
          description: "The current function name to rename (e.g. 'execute')"
        },
        new_name: %{
          type: "string",
          description: "The new function name (e.g. 'dispatch')"
        },
        arity: %{
          type: "integer",
          description: "The function arity (number of arguments)"
        }
      },
      required: ["module", "old_name", "new_name", "arity"]
    }
  end

  # This should never be called directly — Orchestrator intercepts it
  @impl true
  def execute(%{"module" => mod, "old_name" => old, "new_name" => new, "arity" => a}, _opts) do
    {:ok, "rename_mfa intercepted: #{mod}.#{old}/#{a} → #{new}"}
  end

  def execute(_params, _opts), do: {:ok, "rename_mfa intercepted"}
end
