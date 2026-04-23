defmodule Giulia.Storage.Arcade.Indexer do
  @moduledoc """
  Snapshots the completed knowledge graph to ArcadeDB after {:graph_ready}.

  Listens for `{:graph_ready, project_path, build_id}` messages from
  Knowledge.Store and writes a complete, tagged snapshot of modules,
  functions, and dependency edges to ArcadeDB.

  This module is a GenServer registered by name. Knowledge.Store sends
  a message via `send/2` (not a direct function call) to avoid a circular
  dependency: Store -> Indexer -> Store.

  The `snapshot/2` function can also be called directly from iex or tests.
  """

  use GenServer

  require Logger

  alias Giulia.Storage.Arcade.Client
  alias Giulia.Knowledge.Store

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Snapshot the current knowledge graph state for a project to ArcadeDB.

  Reads modules, functions, and dependency edges from Knowledge.Store,
  writes them as a tagged build snapshot. Runs synchronously.
  """
  @spec snapshot(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def snapshot(project_path, build_id) do
    Logger.info("[Arcade.Indexer] Snapshotting build #{build_id} for #{project_path}")
    start = System.monotonic_time(:millisecond)

    with {:ok, _} <- Client.health(),
         :ok <- Client.create_db(),
         :ok <- Client.ensure_schema(),
         {:ok, modules} <- Store.all_modules(project_path),
         {:ok, functions} <- Store.all_functions(project_path),
         {:ok, module_edges} <- Store.all_dependencies(project_path),
         {:ok, function_call_edges} <- Store.all_function_call_edges(project_path) do

      results = %{
        modules: write_modules(project_path, modules, build_id),
        functions: write_functions(project_path, functions, build_id),
        module_edges: write_module_edges(project_path, module_edges, build_id),
        function_call_edges: write_function_call_edges(project_path, function_call_edges, build_id)
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

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_info({:graph_ready, project_path, build_id}, state) do
    # Run snapshot in a separate task to avoid blocking the GenServer
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn -> snapshot(project_path, build_id) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Writers
  # ============================================================================

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

  # Module-level edges only. L3 has explicit types for :depends_on and
  # :implements; module-level :calls (from promote_function_edges_to_module)
  # are *synthesized* for L1 queries and intentionally not persisted — the
  # authoritative CALLS data lives at function level. Same for :references
  # and :semantic, which are L1-only signals today.
  defp write_module_edges(project, edges, build_id) do
    # CREATE EDGE is not idempotent — purge this (project, build_id) first
    # so re-snapshots replace rather than accumulate.
    Client.delete_edges_for_build("DEPENDS_ON", project, build_id)

    {written, dropped} =
      Enum.reduce(edges, {[], %{}}, fn {from, to, type}, {writes, drops} ->
        case type do
          :depends_on ->
            {[Client.insert_dependency(project, from, to, build_id) | writes], drops}

          :implements ->
            {[Client.insert_dependency(project, from, to, build_id) | writes], drops}

          other ->
            {writes, Map.update(drops, other, 1, &(&1 + 1))}
        end
      end)

    if map_size(dropped) > 0 do
      Logger.debug(
        "[Arcade.Indexer] Module-edge types intentionally not persisted to L3: #{inspect(dropped)}"
      )
    end

    Map.put(count_results(written), :dropped_by_type, dropped)
  end

  # Function-level :calls edges. These are the authoritative CALLS edges per
  # the L3 schema (CALLS runs between Function vertices).
  defp write_function_call_edges(project, edges, build_id) do
    Client.delete_edges_for_build("CALLS", project, build_id)

    edges
    |> Enum.map(fn {from_mfa, to_mfa, :calls} ->
      Client.insert_call(project, from_mfa, to_mfa, build_id)
    end)
    |> count_results()
  end

  defp count_results(results) do
    Enum.reduce(results, %{ok: 0, error: 0}, fn
      {:ok, _}, acc -> %{acc | ok: acc.ok + 1}
      {:error, _}, acc -> %{acc | error: acc.error + 1}
    end)
  end
end
