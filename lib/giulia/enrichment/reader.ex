defmodule Giulia.Enrichment.Reader do
  @moduledoc """
  Read-side of the enrichment store. Consumers (`pre_impact_check`,
  the dedicated `/api/intelligence/enrichments` endpoint) call these
  functions to attach tool findings to function vertices and module
  vertices at query time.

  Returns distinguish "never ingested for this project" (`%{}`) from
  "ingested, no findings on this MFA" (`%{credo: []}`). Different
  signals — consumers can act differently on each.
  """

  alias Giulia.Persistence.Store

  @type project_path :: String.t()
  @type mfa_string :: String.t()
  @type module_name :: String.t()
  @type findings_by_tool :: %{atom() => [map()]}

  @doc """
  Returns the per-tool findings map for a function MFA in the form
  `"Mod.Sub.fn/N"`. Empty map when no tool has been ingested for this
  project; map with empty lists when tools have been ingested but none
  matched this MFA.
  """
  @spec fetch_for_mfa(project_path(), mfa_string()) :: findings_by_tool()
  def fetch_for_mfa(project_path, mfa) when is_binary(project_path) and is_binary(mfa) do
    tools = tools_ingested(project_path)
    fetch_targets(project_path, tools, mfa)
  end

  @doc """
  Returns the per-tool findings map for a module-scoped vertex.
  Same `%{}` vs `%{tool: []}` distinction as `fetch_for_mfa/2`.
  """
  @spec fetch_for_module(project_path(), module_name()) :: findings_by_tool()
  def fetch_for_module(project_path, module)
      when is_binary(project_path) and is_binary(module) do
    tools = tools_ingested(project_path)
    fetch_targets(project_path, tools, module)
  end

  @doc """
  Returns the set of tool names with at least one ingested run for
  this project. Walks the registered source list and probes each tool's
  per-project key range. Used by consumers to short-circuit: no point
  asking per-MFA when the project has never been enriched.
  """
  @spec tools_ingested(project_path()) :: [atom()]
  def tools_ingested(project_path) when is_binary(project_path) do
    case Store.get_db(project_path) do
      {:ok, db} ->
        Giulia.Enrichment.Registry.sources()
        |> Map.keys()
        |> Enum.filter(fn tool -> tool_has_findings?(db, tool, project_path) end)

      _ ->
        []
    end
  end

  defp tool_has_findings?(db, tool, project_path) do
    # Sentinel marker is written by Writer.replace_for/3 on every ingest
    # — including empty ingests — so this distinguishes "never ran" from
    # "ran, produced zero findings."
    CubDB.has_key?(db, {:enrichment, tool, project_path, :__ingested__})
  end

  defp fetch_targets(_project_path, [], _target), do: %{}

  defp fetch_targets(project_path, tools, target) do
    case Store.get_db(project_path) do
      {:ok, db} ->
        Enum.into(tools, %{}, fn tool ->
          key = {:enrichment, tool, project_path, target}
          {tool, CubDB.get(db, key, [])}
        end)

      _ ->
        %{}
    end
  end
end
