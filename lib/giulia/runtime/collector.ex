defmodule Giulia.Runtime.Collector do
  @moduledoc """
  Periodic Runtime Snapshot Collector — Temporal Awareness.

  GenServer that periodically calls `Inspector.pulse/1` and stores
  results in an ETS ring buffer. Enables trend detection, alert
  generation, and temporal queries ("memory grew 40% in 10 minutes").

  ## Multi-Node Support

  Watches one or more BEAM nodes. Default: `[:local]` (self only).
  Call `watch_node/1` to add a remote node (e.g., after AutoConnect
  establishes a distributed Erlang connection).

  ## Burst Detection (Monitor Mode)

  When watching a remote node, the Collector detects activity bursts
  (e.g., a scan starting on the worker) by monitoring reductions/s.
  On spike detection, switches to high-frequency sampling (500ms).
  When activity drops, emits a `:profile_ready` notification.

  State machine: IDLE (poll 5s) -> CAPTURING (sample 500ms) -> back to IDLE.

  ## Performance

  `pulse/1` is cheap (5 BIFs). `top_processes/2` is expensive (iterates
  every PID). During idle mode, top_processes is only collected every
  `@heavy_tick_interval` ticks (~4 minutes). During capture mode,
  top_processes is collected every tick (500ms — need full data).
  """

  use GenServer

  alias Giulia.Runtime.Inspector

  require Logger

  @default_idle_interval 5_000
  @default_capture_interval 500
  @default_buffer_size 600
  @ets_table :giulia_runtime_snapshots

  # Collect top_processes every Nth tick during idle (expensive: iterates all PIDs)
  @heavy_tick_interval 4

  # Burst detection: switch to capturing when reductions/s exceeds 3x baseline
  @burst_spike_multiplier 3
  # Return to idle when activity drops below 1.5x baseline for N consecutive samples
  @burst_drop_multiplier 1.5
  @burst_drop_consecutive 3

  # Alert thresholds
  @high_memory_mb 512
  @high_process_count 50_000
  @high_run_queue 5
  @high_message_queue 100

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a remote node to the watch list. Called by AutoConnect after
  establishing a distributed Erlang connection.
  """
  @spec watch_node(atom()) :: :ok
  def watch_node(node_atom) when is_atom(node_atom) do
    GenServer.cast(__MODULE__, {:watch_node, node_atom})
  end

  @doc """
  Returns the last N snapshots for a node.
  """
  @spec history(atom(), keyword()) :: list(map())
  def history(node_ref \\ :local, opts \\ []) do
    last_n = Keyword.get(opts, :last, 20)

    @ets_table
    |> ets_safe_tab()
    |> case do
      nil ->
        []

      _tab ->
        node_key = resolve_key(node_ref)

        :ets.select(@ets_table, [
          {{{node_key, :_}, :_}, [], [:"$_"]}
        ])
        |> Enum.sort_by(fn {{_, ts}, _} -> ts end, :desc)
        |> Enum.take(last_n)
        |> Enum.map(fn {{_, _ts}, snapshot} -> snapshot end)
        |> Enum.reverse()
    end
  end

  @doc """
  Returns a time-series for a single metric.
  """
  @spec trend(atom(), atom()) :: list(map())
  def trend(node_ref \\ :local, metric \\ :memory) do
    snapshots = history(node_ref, last: 20)

    Enum.map(snapshots, fn snapshot ->
      value = extract_metric(snapshot, metric)
      %{timestamp: snapshot[:timestamp], value: value}
    end)
  end

  @doc """
  Returns active alerts with duration information.
  """
  @spec alerts(atom()) :: list(map())
  def alerts(node_ref \\ :local) do
    snapshots = history(node_ref)

    if Enum.empty?(snapshots) do
      []
    else
      latest = List.last(snapshots)
      check_alerts(snapshots, latest)
    end
  end

  @doc """
  Returns whether the collector is actively collecting for any node.
  """
  @spec active?() :: boolean()
  def active? do
    case ets_safe_tab(@ets_table) do
      nil -> false
      _tab -> :ets.info(@ets_table, :size) > 0
    end
  end

  @doc """
  Returns the current collector mode (:idle or :capturing) and watched nodes.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    idle_interval = Keyword.get(opts, :idle_interval_ms, @default_idle_interval)
    capture_interval = Keyword.get(opts, :capture_interval_ms, @default_capture_interval)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    node_ref = Keyword.get(opts, :node, :local)

    # Create ETS table for ring buffer
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :ordered_set, :public])
    end

    state = %{
      idle_interval: idle_interval,
      capture_interval: capture_interval,
      buffer_size: buffer_size,
      nodes: [node_ref],
      tick_count: 0,
      # Burst detection state
      mode: :idle,
      baseline_reductions: nil,
      last_reductions: %{},
      drop_count: 0,
      burst_snapshots: [],
      # Profile callback (set by Monitor GenServer)
      profile_callback: nil
    }

    # Start first collection after a short delay (let the system stabilize)
    Process.send_after(self(), :collect, 5_000)

    {:ok, state}
  end

  @impl true
  def handle_cast({:watch_node, node_atom}, state) do
    if node_atom in state.nodes do
      {:noreply, state}
    else
      Logger.info("Collector: now watching node #{node_atom}")
      {:noreply, %{state | nodes: state.nodes ++ [node_atom]}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{mode: state.mode, nodes: state.nodes, tick_count: state.tick_count}, state}
  end

  @impl true
  def handle_info(:collect, state) do
    state = do_collect_all(state)

    # Schedule next collection based on mode
    interval = if state.mode == :capturing, do: state.capture_interval, else: state.idle_interval
    Process.send_after(self(), :collect, interval)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Collection Logic
  # ============================================================================

  defp do_collect_all(state) do
    Enum.reduce(state.nodes, state, fn node_ref, acc ->
      do_collect(acc, node_ref)
    end)
  end

  defp do_collect(state, node_ref) do
    # During capture mode, always collect top_processes (need full data)
    # During idle mode, only on heavy ticks (expensive)
    heavy_tick? = state.mode == :capturing or rem(state.tick_count, @heavy_tick_interval) == 0

    case Inspector.pulse(node_ref) do
      {:ok, pulse} ->
        top_procs =
          if heavy_tick? do
            case Inspector.top_processes(node_ref, :reductions) do
              {:ok, procs} -> Enum.take(procs, 10)
              _ -> []
            end
          else
            []
          end

        snapshot = %{
          timestamp: pulse.timestamp,
          pulse: pulse,
          top_processes: top_procs
        }

        node_key = resolve_key(node_ref)
        ts = System.monotonic_time(:millisecond)

        # Insert into ring buffer
        :ets.insert(@ets_table, {{node_key, ts}, snapshot})

        # Trim old entries beyond buffer_size
        trim_buffer(node_key, state.buffer_size)

        # Burst detection (only for remote nodes, not :local)
        state =
          if node_ref != :local and node_ref != node() do
            detect_burst(state, node_ref, pulse, snapshot)
          else
            state
          end

        %{state | tick_count: state.tick_count + 1}

      {:error, reason} ->
        Logger.debug("Collector: pulse failed for #{inspect(node_ref)}: #{inspect(reason)}")
        state
    end
  end

  # ============================================================================
  # Burst Detection
  # ============================================================================

  defp detect_burst(state, node_ref, pulse, snapshot) do
    current_reductions = get_in(pulse, [:beam, :reductions]) || 0
    last_reductions = Map.get(state.last_reductions, node_ref, current_reductions)
    reductions_delta = current_reductions - last_reductions

    state = put_in(state.last_reductions[node_ref], current_reductions)

    case state.mode do
      :idle ->
        # Update baseline (rolling average of idle reductions/s)
        baseline = state.baseline_reductions || max(reductions_delta, 1)
        new_baseline = trunc(baseline * 0.8 + reductions_delta * 0.2)
        state = %{state | baseline_reductions: new_baseline}

        # Check for spike
        if reductions_delta > baseline * @burst_spike_multiplier and baseline > 0 do
          Logger.info("Collector: burst detected on #{node_ref} — reductions/s #{reductions_delta} vs baseline #{baseline}. Switching to capture mode.")
          %{state | mode: :capturing, drop_count: 0, burst_snapshots: [snapshot]}
        else
          state
        end

      :capturing ->
        # Accumulate burst snapshots
        state = %{state | burst_snapshots: state.burst_snapshots ++ [snapshot]}

        # Check if activity dropped back to baseline
        baseline = state.baseline_reductions || 1

        if reductions_delta < baseline * @burst_drop_multiplier do
          new_drop_count = state.drop_count + 1

          if new_drop_count >= @burst_drop_consecutive do
            Logger.info("Collector: burst ended on #{node_ref} — #{length(state.burst_snapshots)} snapshots captured. Producing profile.")

            # Notify profile callback if set
            if state.profile_callback do
              send(state.profile_callback, {:profile_ready, node_ref, state.burst_snapshots})
            end

            # Reset to idle
            %{state | mode: :idle, drop_count: 0, burst_snapshots: [], baseline_reductions: nil}
          else
            %{state | drop_count: new_drop_count}
          end
        else
          # Activity still high, reset drop counter
          %{state | drop_count: 0}
        end
    end
  end

  # ============================================================================
  # Buffer Management
  # ============================================================================

  defp trim_buffer(node_key, max_size) do
    entries =
      :ets.select(@ets_table, [
        {{{node_key, :_}, :_}, [], [:"$_"]}
      ])

    if length(entries) > max_size do
      entries
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, :asc)
      |> Enum.take(length(entries) - max_size)
      |> Enum.each(fn {key, _} -> :ets.delete(@ets_table, key) end)
    end
  end

  # ============================================================================
  # Alert Detection
  # ============================================================================

  defp check_alerts(snapshots, latest) do
    alerts = []
    beam = latest[:pulse][:beam] || %{}

    # Memory alert
    alerts =
      if (beam[:memory_mb] || 0) > @high_memory_mb do
        duration = alert_duration(snapshots, fn s ->
          (s[:pulse][:beam][:memory_mb] || 0) > @high_memory_mb
        end)

        [%{type: "high_memory", value: beam[:memory_mb],
           threshold: @high_memory_mb, unit: "MB", duration_snapshots: duration} | alerts]
      else
        alerts
      end

    # Process count alert
    alerts =
      if (beam[:processes] || 0) > @high_process_count do
        duration = alert_duration(snapshots, fn s ->
          (s[:pulse][:beam][:processes] || 0) > @high_process_count
        end)

        [%{type: "high_process_count", value: beam[:processes],
           threshold: @high_process_count, duration_snapshots: duration} | alerts]
      else
        alerts
      end

    # Run queue alert
    alerts =
      if (beam[:run_queue] || 0) > @high_run_queue do
        duration = alert_duration(snapshots, fn s ->
          (s[:pulse][:beam][:run_queue] || 0) > @high_run_queue
        end)

        [%{type: "run_queue_pressure", value: beam[:run_queue],
           threshold: @high_run_queue, duration_snapshots: duration} | alerts]
      else
        alerts
      end

    # Message queue alert (check top processes for queue buildup)
    top_procs =
      snapshots
      |> Enum.reverse()
      |> Enum.find_value([], fn s -> if s[:top_processes] != [], do: s[:top_processes] end)

    queue_offenders =
      top_procs
      |> Enum.filter(fn p -> (p[:message_queue] || p.message_queue || 0) > @high_message_queue end)

    alerts =
      if queue_offenders != [] do
        offender_info = Enum.map(queue_offenders, fn p ->
          %{module: p[:module] || p.module, queue: p[:message_queue] || p.message_queue}
        end)

        [%{type: "message_queue_buildup", offenders: offender_info,
           threshold: @high_message_queue} | alerts]
      else
        alerts
      end

    # Memory growth alert (>20% over the snapshot window)
    alerts = check_memory_growth(snapshots, alerts)

    Enum.reverse(alerts)
  end

  defp alert_duration(snapshots, predicate) do
    snapshots
    |> Enum.reverse()
    |> Enum.take_while(predicate)
    |> length()
  end

  defp check_memory_growth(snapshots, alerts) when length(snapshots) < 3, do: alerts

  defp check_memory_growth(snapshots, alerts) do
    first_mem = get_in(List.first(snapshots), [:pulse, :beam, :memory_mb]) || 0
    last_mem = get_in(List.last(snapshots), [:pulse, :beam, :memory_mb]) || 0

    if first_mem > 0 do
      growth_pct = Float.round((last_mem - first_mem) / first_mem * 100, 1)

      if growth_pct > 20.0 do
        [%{type: "memory_growth", from_mb: first_mem, to_mb: last_mem,
           growth_pct: growth_pct, over_snapshots: length(snapshots)} | alerts]
      else
        alerts
      end
    else
      alerts
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_metric(snapshot, :memory),
    do: get_in(snapshot, [:pulse, :beam, :memory_mb])

  defp extract_metric(snapshot, :processes),
    do: get_in(snapshot, [:pulse, :beam, :processes])

  defp extract_metric(snapshot, :run_queue),
    do: get_in(snapshot, [:pulse, :beam, :run_queue])

  defp extract_metric(snapshot, :ets_memory),
    do: get_in(snapshot, [:pulse, :ets, :total_memory_mb])

  defp extract_metric(snapshot, _),
    do: get_in(snapshot, [:pulse, :beam, :memory_mb])

  defp resolve_key(:local), do: node()
  defp resolve_key(n) when is_atom(n), do: n
  defp resolve_key(n) when is_binary(n), do: String.to_atom(n)

  defp ets_safe_tab(table) do
    case :ets.whereis(table) do
      :undefined -> nil
      ref -> ref
    end
  end
end
