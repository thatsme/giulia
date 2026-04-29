defmodule Giulia.Enrichment.Ingest do
  @moduledoc """
  Orchestrator for enrichment ingestion. Resolves the source module
  via `Giulia.Enrichment.Registry`, parses the payload, replaces prior
  findings via `Writer.replace_for/3`, and emits telemetry.

  Telemetry events (day-one, not a follow-up):

    - `[:giulia, :enrichment, :ingest]` — successful ingest
      measurements: `%{count, duration_ms, replaced}`
      metadata: `%{tool, project}`

    - `[:giulia, :enrichment, :parse_error]` — source parser failed
      measurements: `%{count: 1}`
      metadata: `%{tool, project, reason}`
  """

  alias Giulia.Enrichment.{Registry, Writer}

  require Logger

  @type result ::
          {:ok,
           %{
             tool: atom(),
             ingested: non_neg_integer(),
             targets: non_neg_integer(),
             replaced: non_neg_integer()
           }}
          | {:error, term()}

  @doc """
  Validate inputs and run an enrichment ingest. Single source of truth
  for the validation cascade shared between HTTP `POST /api/index/enrichment`
  and the MCP `index_enrichment` tool.

  Returns:
    * `{:ok, summary}` — ingest succeeded
    * `{:error, {:invalid_tool, _}}` — tool string empty or non-binary
    * `{:error, {:invalid_project, project}}` — project path missing or
      didn't resolve to a directory
    * `{:error, {:invalid_payload_path, payload_path}}` — payload path empty
    * `{:error, {:payload_path_not_under_root, payload_path}}` — payload
      not under any allowed root from `ScanConfig.enrichment_payload_roots/0`
    * `{:error, {:payload_not_regular_file, payload_path}}` — path is a
      directory or symlink to one
    * `{:error, reason}` — underlying ingest/parse failure (passes through
      from `run/3`)
  """
  @spec run_with_validation(term(), term(), term()) ::
          result()
          | {:error,
             {:invalid_tool, term()}
             | {:invalid_project, term()}
             | {:invalid_payload_path, term()}
             | {:payload_path_not_under_root, String.t()}
             | {:payload_not_regular_file, String.t()}}
  def run_with_validation(tool, project, payload_path) do
    with :ok <- validate_tool(tool),
         {:ok, resolved_project} <- validate_project(project),
         :ok <- validate_payload_path(payload_path, resolved_project) do
      run(tool, resolved_project, payload_path)
    end
  end

  defp validate_tool(tool) when is_binary(tool) and tool != "", do: :ok
  defp validate_tool(other), do: {:error, {:invalid_tool, other}}

  defp validate_project(project) when is_binary(project) and project != "" do
    resolved = Giulia.Core.PathMapper.resolve_path(project)

    cond do
      not is_binary(resolved) or resolved == "" ->
        {:error, {:invalid_project, project}}

      not File.dir?(resolved) ->
        {:error, {:invalid_project, project}}

      true ->
        {:ok, resolved}
    end
  end

  defp validate_project(other), do: {:error, {:invalid_project, other}}

  defp validate_payload_path(payload_path, resolved_project) when is_binary(payload_path) do
    cond do
      payload_path == "" ->
        {:error, {:invalid_payload_path, payload_path}}

      Giulia.Context.ScanConfig.validate_enrichment_payload_path(
        payload_path,
        resolved_project
      ) != :ok ->
        {:error, {:payload_path_not_under_root, payload_path}}

      not File.regular?(payload_path) ->
        {:error, {:payload_not_regular_file, payload_path}}

      true ->
        :ok
    end
  end

  defp validate_payload_path(other, _resolved_project),
    do: {:error, {:invalid_payload_path, other}}

  @doc """
  Run an enrichment ingest. Returns `{:ok, summary}` on success or
  `{:error, reason}` on parse failure / unknown tool. **Use
  `run_with_validation/3` from protocol layers** — it covers the full
  input cascade. Direct callers (tests, in-process callers) may use
  this when inputs are already trusted.
  """
  @spec run(atom() | String.t(), String.t(), String.t()) :: result()
  def run(tool, project_path, payload_path)
      when is_binary(project_path) and is_binary(payload_path) do
    started = System.monotonic_time(:millisecond)

    with {:ok, source_mod} <- Registry.fetch_source(tool),
         tool_atom = source_mod.tool_name(),
         {:ok, findings} <- source_mod.parse(payload_path, project_path),
         {:ok, %{targets: targets, findings: persisted, replaced: replaced}} <-
           Writer.replace_for(tool_atom, project_path, findings) do
      duration = System.monotonic_time(:millisecond) - started

      :telemetry.execute(
        [:giulia, :enrichment, :ingest],
        %{count: persisted, targets: targets, duration_ms: duration, replaced: replaced},
        %{tool: tool_atom, project: project_path}
      )

      {:ok, %{tool: tool_atom, ingested: persisted, targets: targets, replaced: replaced}}
    else
      :error ->
        :telemetry.execute(
          [:giulia, :enrichment, :parse_error],
          %{count: 1},
          %{tool: tool, project: project_path, reason: :unknown_tool}
        )

        {:error, {:unknown_tool, tool}}

      {:error, reason} = err ->
        :telemetry.execute(
          [:giulia, :enrichment, :parse_error],
          %{count: 1},
          %{tool: tool, project: project_path, reason: reason}
        )

        err
    end
  end
end
