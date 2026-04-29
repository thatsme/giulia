defmodule Giulia.Storage.Arcade.Consolidator do
  @moduledoc """
  Periodic consolidation of ArcadeDB graph history.

  Runs on a schedule (default: every 30 minutes) and after each indexing pass.
  Analyzes cross-build data to surface insights:

  - Complexity drift — modules with monotonically increasing complexity
  - Coupling drift — modules gaining dependency edges across builds
  - Hotspot detection — high complexity AND high coupling in current build

  Insights are written back to ArcadeDB as first-class graph data,
  queryable by Claude Code like any other vertex.

  Build 137: skeleton only — schedule ticking, empty consolidation logic.
  Build 138+: consolidation queries.

  Build 159+: retention pruning. Each scan re-snapshots the current
  build's CALLS / DEPENDS_ON edges into ArcadeDB; prior builds' edges
  accumulate forever because `Client.delete_edges_for_build/3` is
  build-id-scoped (it only purges duplicates of the same snapshot).
  Without pruning, `verify_l3.count_parity.status == "l3_exceeds_l1"`
  reliably even on a healthy system. The Consolidator now drops edges
  older than the configured retention window
  (`ScanConfig.arcade_history_builds/0`, default 10) on each cycle.
  """

  use GenServer

  require Logger

  alias Giulia.Storage.Arcade.Client

  # 30 minutes
  @default_interval_ms 30 * 60 * 1_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a consolidation cycle manually."
  @spec consolidate() :: :ok
  def consolidate do
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc "Get the current consolidation status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval_ms)

    state = %{
      interval: interval,
      last_run: nil,
      run_count: 0,
      last_result: nil
    }

    # Don't run immediately — wait for the first indexing pass to populate data
    schedule_next(interval)

    Logger.info("[Arcade.Consolidator] Started, interval: #{div(interval, 60_000)}m")
    {:ok, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    new_state = run_consolidation(state)
    schedule_next(state.interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:consolidate, state) do
    new_state = run_consolidation(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # ---------------------------------------------------------------------------
  # Pure functions (testable without GenServer)
  # ---------------------------------------------------------------------------

  @doc "Returns true if the list has 2+ elements and each is strictly greater than the previous."
  @spec monotonically_increasing?(list(number())) :: boolean()
  def monotonically_increasing?([]), do: false
  def monotonically_increasing?([_]), do: false
  def monotonically_increasing?([a, b]) when b > a, do: true
  def monotonically_increasing?([_, _]), do: false

  def monotonically_increasing?([a, b | rest]) when b > a do
    monotonically_increasing?([b | rest])
  end

  def monotonically_increasing?(_), do: false

  @doc "Classify complexity severity based on score thresholds."
  @spec classify_complexity_severity(number()) :: String.t()
  def classify_complexity_severity(score) when score >= 50, do: "high"
  def classify_complexity_severity(score) when score >= 20, do: "medium"
  def classify_complexity_severity(_score), do: "low"

  @doc "Classify coupling severity based on score thresholds."
  @spec classify_coupling_severity(number()) :: String.t()
  def classify_coupling_severity(score) when score >= 10, do: "high"
  def classify_coupling_severity(score) when score >= 5, do: "medium"
  def classify_coupling_severity(_score), do: "low"

  @doc "Classify hotspot severity based on score thresholds."
  @spec classify_hotspot_severity(number()) :: String.t()
  def classify_hotspot_severity(score) when score >= 40, do: "high"
  def classify_hotspot_severity(score) when score >= 20, do: "medium"
  def classify_hotspot_severity(_score), do: "low"

  @doc "Group rows by module name, sorted by build_id within each group."
  @spec group_by_module(list(map())) :: list({String.t(), list(map())})
  def group_by_module([]), do: []

  def group_by_module(rows) do
    rows
    |> Enum.group_by(& &1["name"])
    |> Enum.map(fn {name, builds} ->
      {name, Enum.sort_by(builds, & &1["build_id"])}
    end)
  end

  @doc "Detect modules with monotonically increasing complexity across builds."
  @spec detect_complexity_drift(String.t(), integer()) :: list(map())
  def detect_complexity_drift(project, _build_id) do
    case Client.complexity_history(project) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        rows
        |> group_by_module()
        |> Enum.filter(fn {_name, builds} ->
          scores = Enum.map(builds, & &1["complexity_score"])
          length(scores) >= 3 and monotonically_increasing?(scores)
        end)
        |> Enum.map(fn {name, builds} ->
          scores = Enum.map(builds, & &1["complexity_score"])

          %{
            module: name,
            trend: scores,
            severity: classify_complexity_severity(List.last(scores))
          }
        end)

      _ ->
        []
    end
  end

  @doc "Detect modules with monotonically increasing coupling across builds."
  @spec detect_coupling_drift(String.t(), integer()) :: list(map())
  def detect_coupling_drift(project, _build_id) do
    case Client.coupling_history(project) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        rows
        |> group_by_module()
        |> Enum.filter(fn {_name, builds} ->
          fan_in = Enum.map(builds, & &1["dep_in"])
          fan_out = Enum.map(builds, & &1["dep_out"])

          (length(fan_in) >= 3 and monotonically_increasing?(fan_in)) or
            (length(fan_out) >= 3 and monotonically_increasing?(fan_out))
        end)
        |> Enum.map(fn {name, builds} ->
          fan_in = Enum.map(builds, & &1["dep_in"])
          %{module: name, trend: fan_in, severity: classify_coupling_severity(List.last(fan_in))}
        end)

      _ ->
        []
    end
  end

  @doc "Detect hotspot modules in the current build (high complexity + high coupling)."
  @spec detect_hotspots(String.t(), integer()) :: list(map())
  def detect_hotspots(project, build_id) do
    case Client.hotspots(project, build_id, 20) do
      {:ok, rows} when is_list(rows) ->
        Enum.map(rows, fn row ->
          score = row["hotspot_score"] || 0
          %{module: row["name"], score: score, severity: classify_hotspot_severity(score)}
        end)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Consolidation logic
  # ---------------------------------------------------------------------------

  defp run_consolidation(state) do
    case Client.health() do
      {:ok, _} ->
        Logger.info("[Arcade.Consolidator] Running consolidation cycle #{state.run_count + 1}")
        start = System.monotonic_time(:millisecond)

        retention = Giulia.Context.ScanConfig.arcade_history_builds()

        result =
          case Client.list_projects() do
            {:ok, project_rows} ->
              pruned =
                project_rows
                |> Enum.map(fn row -> row["project"] || row[:project] end)
                |> Enum.reject(&(&1 in [nil, ""]))
                |> Enum.map(fn project -> {project, prune_old_builds(project, retention)} end)
                |> Map.new()

              %{status: :ok, retention: retention, pruned: pruned}

            {:error, reason} ->
              %{status: :error, retention: retention, error: inspect(reason)}
          end

        elapsed = System.monotonic_time(:millisecond) - start
        Logger.info("[Arcade.Consolidator] Cycle complete in #{elapsed}ms — #{inspect(result)}")

        %{
          state
          | last_run: DateTime.utc_now(),
            run_count: state.run_count + 1,
            last_result: result
        }

      {:error, reason} ->
        Logger.debug("[Arcade.Consolidator] ArcadeDB unavailable, skipping: #{inspect(reason)}")
        state
    end
  end

  @doc """
  Prune CALLS + DEPENDS_ON edges in ArcadeDB for `project` whose
  `build_id` is older than the most recent `retention` builds.

  Behavior:
    * `retention` < 3 is rejected (caller's responsibility — drift
      detection needs at least 3 builds of history).
    * If the project has fewer builds than the retention window,
      nothing is pruned.
    * The cutoff is `keep_from = Nth-newest build_id`; the SQL
      delete uses `build_id < keep_from`, so the Nth-newest is kept.

  Returns a summary map: `%{kept, pruned, keep_from, calls, depends_on}`
  on success, `%{kept: 0, pruned: 0, error: ...}` on lookup failure,
  or `%{kept: N, pruned: 0}` when no pruning was needed.
  """
  @spec prune_old_builds(String.t(), pos_integer()) :: map()
  def prune_old_builds(project, retention)
      when is_binary(project) and is_integer(retention) and retention >= 3 do
    case Client.list_builds(project) do
      {:ok, builds} when is_list(builds) and builds != [] ->
        build_ids =
          builds
          |> Enum.map(fn row -> row["build_id"] || row[:build_id] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort(:desc)

        if length(build_ids) <= retention do
          %{kept: length(build_ids), pruned: 0}
        else
          keep_from = Enum.at(build_ids, retention - 1)

          calls_result = Client.delete_edges_older_than("CALLS", project, keep_from)
          deps_result = Client.delete_edges_older_than("DEPENDS_ON", project, keep_from)

          %{
            kept: retention,
            pruned: length(build_ids) - retention,
            keep_from: keep_from,
            calls: result_status(calls_result),
            depends_on: result_status(deps_result)
          }
        end

      {:ok, []} ->
        %{kept: 0, pruned: 0}

      {:error, reason} ->
        %{kept: 0, pruned: 0, error: inspect(reason)}
    end
  end

  defp result_status({:ok, _}), do: :ok
  defp result_status({:error, reason}), do: {:error, reason}

  defp schedule_next(interval) do
    Process.send_after(self(), :consolidate, interval)
  end
end
