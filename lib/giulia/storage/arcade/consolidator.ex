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
  """

  use GenServer

  require Logger

  alias Giulia.Storage.Arcade.Client

  @default_interval_ms 30 * 60 * 1_000  # 30 minutes

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a consolidation cycle manually."
  def consolidate do
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc "Get the current consolidation status."
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
  # Consolidation logic
  # ---------------------------------------------------------------------------

  defp run_consolidation(state) do
    case Client.health() do
      {:ok, _} ->
        Logger.info("[Arcade.Consolidator] Running consolidation cycle #{state.run_count + 1}")
        start = System.monotonic_time(:millisecond)

        # Build 138+: consolidation queries go here
        # - complexity_drift(project, last_n_builds)
        # - coupling_drift(project, last_n_builds)
        # - hotspot_detection(project, current_build)
        result = %{status: :ok, insights: 0}

        elapsed = System.monotonic_time(:millisecond) - start
        Logger.info("[Arcade.Consolidator] Cycle complete in #{elapsed}ms — #{inspect(result)}")

        %{state |
          last_run: DateTime.utc_now(),
          run_count: state.run_count + 1,
          last_result: result
        }

      {:error, reason} ->
        Logger.debug("[Arcade.Consolidator] ArcadeDB unavailable, skipping: #{inspect(reason)}")
        state
    end
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :consolidate, interval)
  end
end
