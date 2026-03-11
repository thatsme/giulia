defmodule Giulia.Storage.Arcade.Indexer do
  @moduledoc """
  Snapshots the completed knowledge graph to ArcadeDB after {:graph_ready}.

  Called once per build — writes a complete, tagged snapshot of modules,
  functions, and dependency edges. Never touches in-flight state.

  Reads from Knowledge.Store (ETS) so it's decoupled from the graph
  construction pipeline and can be called from anywhere: the {:graph_ready}
  hook, an HTTP endpoint, or a manual iex trigger.
  """

  require Logger

  alias Giulia.Storage.Arcade.Client
  alias Giulia.Knowledge.Store

  @doc """
  Snapshot the current knowledge graph state for a project to ArcadeDB.

  Reads modules, functions, and dependency edges from Knowledge.Store,
  writes them as a tagged build snapshot. Runs synchronously — caller
  should wrap in `Task.start/1` if async is desired.
  """
  @spec snapshot(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def snapshot(project_path, build_id) do
    Logger.info("[Arcade.Indexer] Snapshotting build #{build_id} for #{project_path}")
    start = System.monotonic_time(:millisecond)

    with {:ok, _} <- Client.health(),
         :ok <- Client.ensure_schema(),
         {:ok, modules} <- Store.all_modules(project_path),
         {:ok, functions} <- Store.all_functions(project_path),
         {:ok, edges} <- Store.all_dependencies(project_path) do

      results = %{
        modules: write_modules(project_path, modules, build_id),
        functions: write_functions(project_path, functions, build_id),
        edges: write_edges(project_path, edges, build_id)
      }

      elapsed = System.monotonic_time(:millisecond) - start
      Logger.info("[Arcade.Indexer] Build #{build_id} snapshot complete in #{elapsed}ms — #{inspect(results)}")
      {:ok, results}
    else
      {:error, reason} ->
        Logger.debug("[Arcade.Indexer] Snapshot skipped: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Writers ---

  defp write_modules(project, modules, build_id) do
    results = Enum.map(modules, fn mod ->
      Client.upsert_module(project, mod.name, build_id)
    end)

    count_results(results)
  end

  defp write_functions(project, functions, build_id) do
    results = Enum.map(functions, fn func ->
      Client.upsert_function(project, func.name, build_id)
    end)

    count_results(results)
  end

  defp write_edges(project, edges, build_id) do
    results = Enum.map(edges, fn {from, to, type} ->
      case type do
        :depends_on -> Client.insert_dependency(project, from, to, build_id)
        :calls -> Client.insert_call(project, from, to, build_id)
        _ -> {:ok, :skipped}
      end
    end)

    count_results(results)
  end

  defp count_results(results) do
    Enum.reduce(results, %{ok: 0, error: 0}, fn
      {:ok, _}, acc -> %{acc | ok: acc.ok + 1}
      {:error, _}, acc -> %{acc | error: acc.error + 1}
    end)
  end
end
