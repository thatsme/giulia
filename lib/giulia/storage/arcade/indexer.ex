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

  # Periodic reconciliation interval. The Indexer cannot trust that
  # every {:graph_ready} message it was sent actually resulted in a
  # snapshot — Knowledge.Store sends via bare send/2 to a whereis
  # lookup, which silently drops on crashes (see GIULIA.md
  # "Restart-time state recovery" — fire-and-forget unack'd delivery
  # branch). The reconciler walks every active project on a timer and
  # snapshots any whose current build is missing from ArcadeDB.
  @reconcile_interval_ms :timer.minutes(5)

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a reconcile pass synchronously. Returns the list of
  `{project_path, build_id}` tuples that were re-snapshotted because
  ArcadeDB lacked the current build.

  Mostly for tests; production calls happen on the periodic timer.
  """
  @spec reconcile_now() :: [{String.t(), integer()}]
  def reconcile_now do
    GenServer.call(__MODULE__, :reconcile_now, 60_000)
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
    schedule_reconcile()
    {:ok, %{in_flight: %{}, pending: %{}}}
  end

  @impl true
  def handle_info({:graph_ready, project_path, build_id}, state) do
    {:noreply, request_snapshot(state, project_path, build_id)}
  end

  def handle_info(:reconcile, state) do
    spawn_reconcile()
    schedule_reconcile()
    {:noreply, state}
  end

  # A snapshot task finished. Release the slot, then run whatever was coalesced
  # while it held it. Matched before the catch-all below, which would otherwise
  # swallow it and leak the slot forever.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case take_in_flight(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {project, state} ->
        case Map.pop(state.pending, project) do
          {nil, pending} ->
            {:noreply, %{state | pending: pending}}

          {build_id, pending} ->
            {:noreply, start_snapshot(%{state | pending: pending}, project, build_id)}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    # Synchronous by contract — callers use the returned list. It still respects
    # the gate: a project already being snapshotted is skipped rather than
    # snapshotted a second time concurrently.
    {:reply, run_reconcile(Map.keys(state.in_flight)), state}
  end

  # ============================================================================
  # Snapshot de-duplication
  # ============================================================================
  #
  # Two snapshots of the same project must never run concurrently. Both write
  # the same (project, build_id) rows, so they collide on ArcadeDB's optimistic
  # page-level MVCC and one loses — which the retry in `Arcade.Client` absorbs,
  # but only by doing the work twice and burning the retry budget on
  # self-inflicted contention. Measured: 6 retry exhaustions per 6 full suite
  # runs, all concentrated in the DELETE that opens each write group.
  #
  # Concurrency arises normally: `{:graph_ready}` fires per rebuild while the
  # reconcile timer can independently decide the same project needs a snapshot.
  #
  # A request arriving while one is in flight is COALESCED rather than dropped.
  # Dropping it would leave L3 pinned at the older build — exactly the silent
  # L1/L3 drift the reconciler exists to prevent. Only the newest build is kept:
  # intermediate ones are already stale by the time the slot frees.

  defp request_snapshot(state, project, build_id) do
    if Map.has_key?(state.in_flight, project) do
      Logger.debug(
        "[Arcade.Indexer] Snapshot already in flight for #{project}; " <>
          "coalescing build #{build_id}"
      )

      %{state | pending: Map.put(state.pending, project, build_id)}
    else
      start_snapshot(state, project, build_id)
    end
  end

  defp start_snapshot(state, project, build_id) do
    case Task.Supervisor.start_child(Giulia.TaskSupervisor, fn -> snapshot(project, build_id) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | in_flight: Map.put(state.in_flight, project, %{ref: ref, build_id: build_id})}

      {:error, reason} ->
        # Never mark in-flight for a task that failed to start, or the slot is
        # held by nothing and the project is never snapshotted again.
        Logger.warning(
          "[Arcade.Indexer] Could not start snapshot task for #{project}: #{inspect(reason)}"
        )

        state
    end
  end

  defp take_in_flight(state, ref) do
    case Enum.find(state.in_flight, fn {_project, %{ref: r}} -> r == ref end) do
      nil -> {nil, state}
      {project, _} -> {project, %{state | in_flight: Map.delete(state.in_flight, project)}}
    end
  end

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
  end

  # The periodic pass routes through the same gate rather than snapshotting
  # directly: discovery does network I/O so it stays off the GenServer, but the
  # decision to snapshot goes back through `{:graph_ready}` so it cannot race a
  # rebuild-triggered snapshot of the same project.
  defp spawn_reconcile do
    parent = self()

    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      Enum.each(projects_needing_snapshot(), fn {project, build_id} ->
        Logger.info(
          "[Arcade.Indexer] Reconcile: #{project} missing build #{build_id}, requesting snapshot"
        )

        send(parent, {:graph_ready, project, build_id})
      end)
    end)
  end

  # Projects whose current build is absent from ArcadeDB.
  defp projects_needing_snapshot do
    current_build = Giulia.Version.build()

    Store.list_projects()
    |> Enum.filter(fn project -> needs_snapshot?(project, current_build) end)
    |> Enum.map(fn project -> {project, current_build} end)
  end

  # Synchronous reconcile for `reconcile_now/0`. Returns the list of
  # `{project, build_id}` actually re-snapshotted, skipping any project whose
  # snapshot is already running.
  defp run_reconcile(skip) do
    skip = MapSet.new(skip)

    projects_needing_snapshot()
    |> Enum.reject(fn {project, _build} -> MapSet.member?(skip, project) end)
    |> Enum.map(fn {project, build_id} ->
      Logger.info(
        "[Arcade.Indexer] Reconcile: #{project} missing build #{build_id}, snapshotting"
      )

      _ = snapshot(project, build_id)
      {project, build_id}
    end)
  end

  defp needs_snapshot?(project, current_build) do
    case Client.list_builds(project) do
      {:ok, builds} ->
        not Enum.any?(builds, fn row ->
          row["build_id"] == current_build or row[:build_id] == current_build
        end)

      {:error, reason} ->
        Logger.debug(
          "[Arcade.Indexer] Reconcile skipped for #{project}: #{inspect(reason)}"
        )

        false
    end
  end

  # ============================================================================
  # Writers
  # ============================================================================

  defp write_modules(project, modules, build_id) do
    results = Enum.map(modules, fn mod ->
      Client.upsert_module(project, mod.name, build_id)
    end)

    count_results(results, "module")
  end

  defp write_functions(project, functions, build_id) do
    results = Enum.map(functions, fn func ->
      Client.upsert_function(project, func.name, build_id)
    end)

    count_results(results, "function")
  end

  # Module-level edges only. L3 has explicit types for :depends_on and
  # :implements; module-level :calls (from promote_function_edges_to_module)
  # are *synthesized* for L1 queries and intentionally not persisted — the
  # authoritative CALLS data lives at function level. Same for :references
  # and :semantic, which are L1-only signals today.
  defp write_module_edges(project, edges, build_id) do
    # CREATE EDGE is not idempotent — purge this (project, build_id) first
    # so re-snapshots replace rather than accumulate.
    case purge!("DEPENDS_ON", project, build_id) do
      :ok ->
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

        Map.put(count_results(written, "module_edge"), :dropped_by_type, dropped)

      {:error, _reason} ->
        %{ok: 0, error: 1, purge_failed: true, dropped_by_type: %{}}
    end
  end

  # Function-level :calls edges. These are the authoritative CALLS edges per
  # the L3 schema (CALLS runs between Function vertices).
  defp write_function_call_edges(project, edges, build_id) do
    case purge!("CALLS", project, build_id) do
      :ok ->
        edges
        |> Enum.map(fn {from_mfa, to_mfa, :calls} ->
          Client.insert_call(project, from_mfa, to_mfa, build_id)
        end)
        |> count_results("function_call_edge")

      {:error, _reason} ->
        %{ok: 0, error: 1, purge_failed: true}
    end
  end

  # A failed purge is more damaging than a failed insert, and was previously
  # discarded entirely. CREATE EDGE is not idempotent, so inserting on top of a
  # build whose edges were not removed ACCUMULATES them — L3 then exceeds L1,
  # which is precisely the `l3_exceeds_l1` drift Arcade.Verifier reports. Abort
  # the write group instead of corrupting the snapshot.
  defp purge!(edge_type, project, build_id) do
    case Client.delete_edges_for_build(edge_type, project, build_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Arcade.Indexer] #{edge_type} purge failed for #{project} build #{build_id} — " <>
            "skipping inserts to avoid accumulating duplicate edges: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The reason must be logged, not just counted. A snapshot summary of
  # `%{ok: 1, error: 1}` tells an operator that L3 silently lost a write and
  # nothing about why — the same blindness applies to anyone debugging a
  # verifier failure, since `Indexer.snapshot/2` still returns `{:ok, summary}`
  # on a partial write.
  defp count_results(results, kind) do
    Enum.reduce(results, %{ok: 0, error: 0}, fn
      {:ok, _}, acc ->
        %{acc | ok: acc.ok + 1}

      {:error, reason}, acc ->
        Logger.warning("[Arcade.Indexer] #{kind} write failed: #{inspect(reason)}")
        %{acc | error: acc.error + 1}
    end)
  end
end
