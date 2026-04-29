defmodule Giulia.MCP.Dispatch.Index do
  @moduledoc """
  MCP dispatch handlers for the `index_*` tool family.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Context.Indexer
  alias Giulia.Context.Store.{Formatter, Query}
  alias Giulia.Enrichment.Ingest
  alias Giulia.Persistence.Store

  @spec modules(map()) :: {:ok, map()} | {:error, String.t()}
  def modules(args) do
    with {:ok, path} <- require_path(args) do
      modules = Query.list_modules(path)
      {:ok, %{modules: modules, count: length(modules)}}
    end
  end

  @spec functions(map()) :: {:ok, map()} | {:error, String.t()}
  def functions(args) do
    with {:ok, path} <- require_path(args) do
      module_filter = args["module"]
      functions = Query.list_functions(path, module_filter)
      {:ok, %{functions: functions, count: length(functions), module: module_filter}}
    end
  end

  @spec module_details(map()) :: {:ok, map()} | {:error, String.t()}
  def module_details(args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      details = Formatter.module_details(path, module)
      {:ok, %{module: module, details: details}}
    end
  end

  @spec summary(map()) :: {:ok, map()} | {:error, String.t()}
  def summary(args) do
    with {:ok, path} <- require_path(args) do
      summary = Formatter.project_summary(path)
      {:ok, %{summary: summary}}
    end
  end

  @spec status(map()) :: {:ok, map()}
  def status(args), do: {:ok, Indexer.status_with_cache(args["path"])}

  @spec scan(map()) :: {:ok, map()} | {:error, String.t()}
  def scan(args) do
    with {:ok, path} <- require_path(args) do
      Indexer.scan(path)
      {:ok, %{status: "scanning", path: path}}
    end
  end

  @spec verify(map()) :: {:ok, map()} | {:error, String.t()}
  def verify(args) do
    with {:ok, path} <- require_path(args) do
      Store.verify_cache(path)
    end
  end

  @spec compact(map()) :: {:ok, map()} | {:error, String.t()}
  def compact(args) do
    with {:ok, path} <- require_path(args) do
      case Store.compact(path) do
        :ok -> {:ok, %{status: "compacting", path: path}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @spec enrichment(map()) :: {:ok, term()} | {:error, String.t()}
  def enrichment(args) do
    with {:ok, tool} <- require_param(args, "tool"),
         {:ok, project} <- require_param(args, "project"),
         {:ok, payload_path} <- require_param(args, "payload_path") do
      case Ingest.run_with_validation(tool, project, payload_path) do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, format_enrichment_error(reason)}
      end
    end
  end

  defp format_enrichment_error({:invalid_tool, _}), do: "Missing or invalid :tool"

  defp format_enrichment_error({:invalid_project, received}),
    do:
      "Missing or invalid :project (must resolve to an existing directory): #{inspect(received)}"

  defp format_enrichment_error({:invalid_payload_path, _}),
    do: "Missing or invalid :payload_path"

  defp format_enrichment_error({:payload_path_not_under_root, received}),
    do: "payload_path not under any allowed root: #{received}"

  defp format_enrichment_error({:payload_not_regular_file, received}),
    do: "payload_path is not a regular file: #{received}"

  defp format_enrichment_error(other), do: inspect(other)

  @spec complexity(map()) :: {:ok, map()} | {:error, String.t()}
  def complexity(args) do
    with {:ok, path} <- require_path(args) do
      {:ok,
       Query.functions_by_complexity(path,
         module: args["module"],
         min: parse_int(args["min"], 0),
         limit: parse_int(args["limit"], 50)
       )}
    end
  end
end
