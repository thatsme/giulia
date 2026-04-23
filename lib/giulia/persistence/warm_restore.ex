defmodule Giulia.Persistence.WarmRestore do
  @moduledoc """
  Startup warm-restore from L2 (CubDB) into L1 (ETS).

  The L1 ETS tables (`Giulia.Context.Store`, `Giulia.Knowledge.Store`)
  are in-memory and start empty on every BEAM boot. L2 (per-project
  CubDB) persists to disk and survives restarts. Without this module,
  `GET /api/projects` returns an empty list after `docker compose
  restart` until the user triggers a scan — which re-reads the
  filesystem and re-builds L1 from source, slower and heavier than
  reading the L2 cache.

  Flow on startup:

    1. Enumerate candidate project roots (the container's `/projects`
       dir plus `GIULIA_PROJECTS_PATH` if set).
    2. For each project, check whether the role-specific CubDB
       directory exists on disk. Skip if absent (avoids the side
       effect of `Persistence.Store.get_db/1` creating an empty dir).
    3. Call `Loader.restore_graph/1` and `Loader.restore_metrics/1`
       for each surviving project. AST-level restore is intentionally
       skipped — it's expensive and not needed for the dropdown /
       graph endpoints to work.

  The work runs in `handle_info(:run, _)` (scheduled from `init/1`
  via `send/2`) so the supervisor start isn't blocked on I/O.
  """
  use GenServer

  require Logger

  alias Giulia.Persistence.Loader

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Current restore status. Returns a map with `:status` (`:pending` |
  `:done`), `:restored` (list of project paths where restore_graph
  succeeded), and `:attempted` (total projects considered).
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Synchronously restore the given list of project paths. Used by
  tests to bypass filesystem discovery and by `handle_info(:run,
  _)` after it discovers projects from disk. Returns the list of
  projects where `restore_graph/1` succeeded.
  """
  @spec run_for([String.t()]) :: [String.t()]
  def run_for(project_paths) when is_list(project_paths) do
    Enum.reduce(project_paths, [], fn project, acc ->
      case Loader.restore_graph(project) do
        :ok ->
          # Metrics are best-effort — a restore_graph success with
          # no metrics cache is a valid state (older snapshots).
          _ = Loader.restore_metrics(project)
          Logger.info("[WarmRestore] Restored graph for #{project}")
          [project | acc]

        :not_cached ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(_) do
    send(self(), :run)
    {:ok, %{status: :pending, restored: [], attempted: 0}}
  end

  @impl true
  def handle_info(:run, state) do
    started = System.monotonic_time(:millisecond)
    projects = discover_projects()
    restored = run_for(projects)
    elapsed = System.monotonic_time(:millisecond) - started

    Logger.info(
      "[WarmRestore] Completed in #{elapsed}ms: " <>
        "#{length(restored)}/#{length(projects)} projects restored from L2 cache"
    )

    {:noreply,
     %{state | status: :done, restored: restored, attempted: length(projects)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # ============================================================================
  # Discovery
  # ============================================================================

  @doc false
  @spec discover_projects() :: [String.t()]
  def discover_projects do
    candidate_project_roots()
    |> Enum.flat_map(&projects_under/1)
    |> Enum.filter(&has_role_cubdb?/1)
    |> Enum.uniq()
  end

  defp candidate_project_roots do
    # `/projects` is the canonical container mount point (see
    # `Giulia.Core.PathMapper`). Honor `GIULIA_PROJECTS_PATH` too so
    # non-container runs still warm-restore.
    ["/projects", System.get_env("GIULIA_PROJECTS_PATH")]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  defp projects_under(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  # Check whether the project has a CubDB directory for the current
  # role. Mirrors `Persistence.Store.cubdb_dir/1` so we only consider
  # projects that our running role can actually open.
  defp has_role_cubdb?(project_path) do
    role = Giulia.Role.role()

    dir_name =
      if role == :standalone, do: "cubdb", else: "cubdb_#{role}"

    cubdb_path = Path.join([project_path, ".giulia", "cache", dir_name])
    File.dir?(cubdb_path)
  end
end
