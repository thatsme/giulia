defmodule Giulia.Runtime.IngestStore do
  @moduledoc """
  Ingest Store — Build 135.

  Receives runtime snapshots pushed by the Monitor container and stores them
  in ETS. On finalize, aggregates all snapshots into a fused profile using
  the Profiler and Knowledge Graph, then makes it available for LLM queries.

  ## Flow

      Monitor pushes snapshots → IngestStore buffers in ETS
      Monitor sends finalize   → IngestStore crunches + fuses with static data
      Claude Code queries      → IngestStore returns fused observation

  ## Storage

  - Active snapshots: ETS `:giulia_ingested_snapshots` keyed by `{session_id, timestamp}`
  - Finalized observations: ETS `:giulia_observations` keyed by `session_id`
  - Persistent copy: CubDB under `{:observation, session_id}`
  """

  use GenServer

  alias Giulia.Runtime.Profiler
  alias Giulia.Persistence.Store, as: PersistenceStore

  require Logger

  @snapshots_table :giulia_ingested_snapshots
  @observations_table :giulia_observations
  @max_observations 20

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ingest a single runtime snapshot from the Monitor.
  Non-blocking — returns immediately.
  """
  @spec ingest(map()) :: {:ok, map()} | {:error, term()}
  def ingest(snapshot) do
    GenServer.call(__MODULE__, {:ingest, snapshot})
  end

  @doc """
  Finalize a session — aggregate all snapshots into a fused profile.
  """
  @spec finalize(map()) :: {:ok, map()} | {:error, term()}
  def finalize(params) do
    GenServer.call(__MODULE__, {:finalize, params}, 30_000)
  end

  @doc """
  List all available observations.
  """
  @spec list_observations() :: list(map())
  def list_observations do
    case ets_safe_tab(@observations_table) do
      nil -> []
      _tab ->
        :ets.tab2list(@observations_table)
        |> Enum.map(fn {_key, obs} -> obs end)
        |> Enum.sort_by(fn o -> o[:stopped_at] || o[:started_at] end, :desc)
    end
  end

  @doc """
  Get a specific observation by session_id.
  """
  @spec get_observation(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_observation(session_id) do
    case ets_safe_tab(@observations_table) do
      nil -> {:error, :not_found}
      _tab ->
        case :ets.lookup(@observations_table, session_id) do
          [{^session_id, obs}] -> {:ok, obs}
          [] -> {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@snapshots_table) == :undefined do
      :ets.new(@snapshots_table, [:named_table, :ordered_set, :public])
    end

    if :ets.whereis(@observations_table) == :undefined do
      :ets.new(@observations_table, [:named_table, :set, :public])
    end

    state = %{
      active_sessions: %{}  # session_id => %{node, started_at, count}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ingest, snapshot}, _from, state) do
    session_id = snapshot["session_id"] || generate_session_id()
    node = snapshot["node"] || "unknown"
    timestamp = snapshot["timestamp"] || DateTime.utc_now() |> DateTime.to_iso8601()

    # Store snapshot in ETS
    key = {session_id, timestamp}
    :ets.insert(@snapshots_table, {key, normalize_snapshot(snapshot)})

    # Track session metadata
    session_meta = Map.get(state.active_sessions, session_id, %{
      node: node,
      started_at: timestamp,
      count: 0
    })

    session_meta = %{session_meta | count: session_meta.count + 1}
    active_sessions = Map.put(state.active_sessions, session_id, session_meta)

    reply = %{
      status: "ok",
      session_id: session_id,
      snapshot_count: session_meta.count
    }

    {:reply, {:ok, reply}, %{state | active_sessions: active_sessions}}
  end

  def handle_call({:finalize, params}, _from, state) do
    session_id = params["session_id"]
    node = params["node"] || "unknown"
    started_at = params["started_at"]
    stopped_at = params["stopped_at"] || DateTime.utc_now() |> DateTime.to_iso8601()
    project_path = params["project_path"]

    # Collect all snapshots for this session
    snapshots = collect_session_snapshots(session_id)

    if Enum.empty?(snapshots) do
      {:reply, {:error, :no_snapshots}, state}
    else
      # Convert ingested snapshots to the format Profiler expects
      profiler_snapshots = Enum.map(snapshots, &to_profiler_format/1)

      # Use Profiler to fuse with static analysis
      profile = Profiler.produce_profile(profiler_snapshots, project_path, burst_start: parse_datetime(started_at))

      # Aggregate trace data across all snapshots into per-function hotspots
      trace_hotspots = aggregate_trace_calls(snapshots)
      profile = if trace_hotspots != [], do: Map.put(profile, :trace_hotspots, trace_hotspots), else: profile

      # Build the observation record
      observation = %{
        session_id: session_id,
        node: node,
        started_at: started_at,
        stopped_at: stopped_at,
        status: "available",
        snapshots_processed: length(snapshots),
        duration_ms: profile.duration_ms,
        profile: profile
      }

      # Store in observations ETS
      :ets.insert(@observations_table, {session_id, observation})

      # Persist to CubDB if project_path available
      persist_observation(project_path, session_id, observation)

      # Clean up ingested snapshots for this session
      cleanup_session_snapshots(session_id)

      # Trim old observations
      trim_observations()

      # Remove from active sessions
      active_sessions = Map.delete(state.active_sessions, session_id)

      reply = %{
        status: "finalized",
        session_id: session_id,
        node: node,
        duration_seconds: div(profile.duration_ms, 1000),
        snapshots_processed: length(snapshots),
        fused_profile: %{
          hot_modules: Enum.map(profile.hot_modules, fn m -> m[:module] || m.module end),
          peak_memory_mb: profile.peak.memory_mb,
          avg_memory_mb: calculate_avg_memory(profiler_snapshots),
          peak_run_queue: profile.peak.run_queue,
          correlation_count: length(Enum.filter(profile.hot_modules, fn m ->
            m[:knowledge_graph] != nil
          end)),
          trace_hotspot_count: length(trace_hotspots)
        }
      }

      {:reply, {:ok, reply}, %{state | active_sessions: active_sessions}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Snapshot Handling
  # ============================================================================

  defp normalize_snapshot(snapshot) do
    %{
      timestamp: snapshot["timestamp"],
      node: snapshot["node"],
      session_id: snapshot["session_id"],
      metrics: snapshot["metrics"] || %{},
      hot_processes: snapshot["hot_processes"] || [],
      ets_snapshot: snapshot["ets_snapshot"] || [],
      trace_calls: snapshot["trace_calls"] || []
    }
  end

  defp to_profiler_format(snapshot) do
    metrics = snapshot.metrics

    # Build a pulse-compatible map from ingested metrics
    pulse = %{
      timestamp: snapshot.timestamp,
      beam: %{
        memory_mb: metrics["memory_mb"] || 0,
        processes: metrics["process_count"] || 0,
        run_queue: metrics["run_queue"] || 0,
        reductions: metrics["reductions_per_sec"] || 0,
        schedulers: metrics["schedulers_online"] || 0
      },
      ets: %{
        tables: metrics["ets_tables"] || 0,
        total_memory_mb: 0
      }
    }

    # Convert hot_processes to the format top_processes expects
    top_processes =
      (snapshot.hot_processes || [])
      |> Enum.map(fn p ->
        %{
          module: p["module"],
          reductions: p["reductions"] || 0,
          memory_kb: p["memory_kb"] || 0,
          message_queue: p["message_queue"] || 0,
          metric_value: p["reductions"] || 0
        }
      end)

    %{
      timestamp: snapshot.timestamp,
      pulse: pulse,
      top_processes: top_processes,
      trace_calls: snapshot.trace_calls || []
    }
  end

  defp collect_session_snapshots(session_id) do
    case ets_safe_tab(@snapshots_table) do
      nil -> []
      _tab ->
        :ets.select(@snapshots_table, [
          {{{session_id, :_}, :"$1"}, [], [:"$1"]}
        ])
    end
  end

  defp cleanup_session_snapshots(session_id) do
    case ets_safe_tab(@snapshots_table) do
      nil -> :ok
      _tab ->
        keys =
          :ets.select(@snapshots_table, [
            {{{session_id, :_}, :_}, [], [:"$_"]}
          ])
          |> Enum.map(fn {key, _} -> key end)

        Enum.each(keys, fn key -> :ets.delete(@snapshots_table, key) end)
    end
  end

  # ============================================================================
  # Persistence
  # ============================================================================

  defp persist_observation(nil, _session_id, _observation), do: :ok

  defp persist_observation(project_path, session_id, observation) do
    case PersistenceStore.get_db(project_path) do
      {:ok, db} ->
        CubDB.put(db, {:observation, session_id}, observation)

      {:error, reason} ->
        Logger.warning("IngestStore: failed to persist observation — #{inspect(reason)}")
    end
  end

  defp trim_observations do
    case ets_safe_tab(@observations_table) do
      nil -> :ok
      _tab ->
        observations = :ets.tab2list(@observations_table)

        if length(observations) > @max_observations do
          observations
          |> Enum.sort_by(fn {_, obs} -> obs[:stopped_at] end, :asc)
          |> Enum.take(length(observations) - @max_observations)
          |> Enum.each(fn {key, _} -> :ets.delete(@observations_table, key) end)
        end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp aggregate_trace_calls(snapshots) do
    snapshots
    |> Enum.flat_map(fn s -> s.trace_calls || [] end)
    |> Enum.group_by(fn call ->
      mod = call["module"] || call[:module]
      func = call["function"] || call[:function]
      arity = call["arity"] || call[:arity]
      {mod, func, arity}
    end)
    |> Enum.map(fn {{mod, func, arity}, calls} ->
      total = Enum.sum(Enum.map(calls, fn c -> c["call_count"] || c[:call_count] || 0 end))
      %{
        module: mod,
        function: func,
        arity: arity,
        total_calls: total,
        sample_count: length(calls)
      }
    end)
    |> Enum.sort_by(& &1.total_calls, :desc)
    |> Enum.take(50)
  end

  defp generate_session_id do
    "obs_" <> (DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[^0-9]/, ""))
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp calculate_avg_memory(snapshots) do
    memories =
      snapshots
      |> Enum.map(fn s -> get_in(s, [:pulse, :beam, :memory_mb]) || 0 end)
      |> Enum.reject(&(&1 == 0))

    if Enum.empty?(memories) do
      0
    else
      Float.round(Enum.sum(memories) / length(memories), 1)
    end
  end

  defp ets_safe_tab(table) do
    case :ets.whereis(table) do
      :undefined -> nil
      ref -> ref
    end
  end
end
