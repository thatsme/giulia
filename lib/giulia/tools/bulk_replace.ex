defmodule Giulia.Tools.BulkReplace do
  @moduledoc """
  Batch find-and-replace across multiple files in one tool call.

  The Architect's answer to "Finish Line Bias": instead of making the LLM
  call edit_file 22 times (and give up after 2), this tool stages all
  replacements atomically in the Orchestrator's staging buffer.

  Like commit_changes, this is a pseudo-tool — the Orchestrator intercepts
  the call and performs the actual staging logic. The tool exists so the LLM
  can discover and call it.

  Parameters:
    - pattern:     The exact string (or regex) to find
    - replacement: The string to replace it with
    - file_list:   List of file paths to apply the replacement to
                   (typically from get_impact_map downstream results)
    - regex:       If true, treat pattern as a regex (default: false)
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "bulk_replace"

  @impl true
  def description do
    "Find-and-replace a pattern across multiple files in one call. " <>
      "All changes are staged atomically. Use after get_impact_map to rename across dependents."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "The exact string to find (e.g., 'Registry.execute')"
        },
        replacement: %{
          type: "string",
          description: "The replacement string (e.g., 'Registry.dispatch')"
        },
        file_list: %{
          type: "array",
          items: %{type: "string"},
          description: "List of file paths to apply the replacement to"
        },
        regex: %{
          type: "boolean",
          description: "If true, treat pattern as a regex (default: false)"
        }
      },
      required: ["pattern", "replacement", "file_list"]
    }
  end

  # This should never be called directly — Orchestrator intercepts it
  def execute(%{"pattern" => p, "replacement" => r, "file_list" => _files}, _opts) do
    {:ok, "bulk_replace intercepted: '#{p}' → '#{r}'"}
  end

  def execute(_params, _opts), do: {:ok, "bulk_replace intercepted"}
end
