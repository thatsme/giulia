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
  Run an enrichment ingest. Returns `{:ok, summary}` on success or
  `{:error, reason}` on parse failure / unknown tool.
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
