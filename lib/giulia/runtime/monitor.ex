defmodule Giulia.Runtime.Monitor do
  @moduledoc """
  Monitor Lifecycle Orchestrator — Build 132.

  Manages the monitor container's boot sequence and burst profiling lifecycle.
  Only starts in monitor mode (GIULIA_ROLE=monitor); returns `:ignore` otherwise.

  ## State Machine

      BOOT → CONNECT → WATCH → (burst detected) → PROFILING → WATCH
        │        │        │
        └────────┴────────┘  (non-blocking polling via Process.send_after)

  - **BOOT**: Scan Giulia's own source code, build Knowledge Graph
  - **CONNECT**: Wait for AutoConnect to establish distributed Erlang
  - **WATCH**: Idle — Collector monitors worker, detects bursts
  - **PROFILING**: Burst ended — fuse runtime snapshots with static analysis

  Profiles are saved to CubDB under `{:profile, project_path, timestamp}`.
  """

  use GenServer

  alias Giulia.Runtime.{AutoConnect, Collector, Profiler}
  alias Giulia.Persistence.Store, as: PersistenceStore

  require Logger

  @giulia_source_path "/projects/Giulia"
  @scan_poll_ms 500
  @connect_poll_ms 1_000
  @max_profiles 50

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current monitor state (phase + metadata)."
  @spec status() :: map()
  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> %{phase: :not_running, role: Giulia.Role.role()}
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Returns saved profiles, most recent first."
  @spec list_profiles(keyword()) :: list(map())
  def list_profiles(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    case PersistenceStore.get_db(@giulia_source_path) do
      {:ok, db} ->
        CubDB.select(db,
          min_key: {:profile, "", ""},
          max_key: {:profile, "\xFF", "\xFF"},
          reverse: true
        )
        |> Enum.take(limit)
        |> Enum.map(fn {{:profile, _path, timestamp}, profile} ->
          Map.put(profile, :id, timestamp)
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Returns a specific profile by timestamp ID."
  @spec get_profile(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_profile(timestamp_id) do
    case PersistenceStore.get_db(@giulia_source_path) do
      {:ok, db} ->
        case CubDB.get(db, {:profile, @giulia_source_path, timestamp_id}) do
          nil -> {:error, :not_found}
          profile -> {:ok, Map.put(profile, :id, timestamp_id)}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Returns the most recent profile."
  @spec latest_profile() :: {:ok, map()} | {:error, :not_found}
  def latest_profile do
    case list_profiles(limit: 1) do
      [profile] -> {:ok, profile}
      [] -> {:error, :not_found}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    unless Giulia.Role.monitor?() do
      return_ignore()
    else
      source_path = Keyword.get(opts, :source_path, @giulia_source_path)

      state = %{
        phase: :boot,
        source_path: source_path,
        burst_start: nil,
        profiles_count: 0
      }

      Logger.info("Monitor: starting boot sequence — scanning #{source_path}")

      # Register as the Collector's profile callback
      Collector.set_profile_callback(self())

      # Trigger scan of Giulia's own source code
      Giulia.Context.Indexer.scan(source_path)

      # Start polling for scan completion
      Process.send_after(self(), :check_scan, @scan_poll_ms)

      {:ok, state}
    end
  end

  defp return_ignore, do: :ignore

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      phase: state.phase,
      source_path: state.source_path,
      profiles_count: state.profiles_count,
      burst_active: state.burst_start != nil
    }

    {:reply, reply, state}
  end

  # --------------------------------------------------------------------------
  # BOOT phase: wait for scan to complete
  # --------------------------------------------------------------------------
  @impl true
  def handle_info(:check_scan, %{phase: :boot} = state) do
    case Giulia.Context.Indexer.status() do
      %{status: :idle} ->
        Logger.info("Monitor: scan complete — transitioning to CONNECT phase")
        Process.send_after(self(), :check_connect, @connect_poll_ms)
        {:noreply, %{state | phase: :connect}}

      _ ->
        Process.send_after(self(), :check_scan, @scan_poll_ms)
        {:noreply, state}
    end
  end

  # --------------------------------------------------------------------------
  # CONNECT phase: wait for AutoConnect to establish Erlang distribution
  # --------------------------------------------------------------------------
  def handle_info(:check_connect, %{phase: :connect} = state) do
    if AutoConnect.connected?() do
      target = AutoConnect.target_node()
      Logger.info("Monitor: connected to #{target} — entering WATCH phase")
      {:noreply, %{state | phase: :watch}}
    else
      Process.send_after(self(), :check_connect, @connect_poll_ms)
      {:noreply, state}
    end
  end

  # --------------------------------------------------------------------------
  # WATCH/PROFILING: handle burst notifications from Collector
  # --------------------------------------------------------------------------
  def handle_info({:burst_started, _node_ref}, state) do
    Logger.info("Monitor: burst detected — capturing snapshots")
    {:noreply, %{state | burst_start: DateTime.utc_now()}}
  end

  def handle_info({:profile_ready, node_ref, snapshots}, state) do
    Logger.info("Monitor: burst ended on #{node_ref} — producing profile (#{length(snapshots)} snapshots)")

    state = %{state | phase: :profiling}

    # Generate profile (pure function, no LLM)
    profile = Profiler.produce_profile(
      snapshots,
      state.source_path,
      burst_start: state.burst_start
    )

    # Save to CubDB
    save_profile(state.source_path, profile)

    # Trim old profiles
    trim_profiles(state.source_path)

    Logger.info("Monitor: profile saved. Returning to WATCH phase.")

    {:noreply, %{state |
      phase: :watch,
      burst_start: nil,
      profiles_count: state.profiles_count + 1
    }}
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Profile Persistence
  # ============================================================================

  defp save_profile(source_path, profile) do
    timestamp = DateTime.to_iso8601(DateTime.utc_now())

    case PersistenceStore.get_db(source_path) do
      {:ok, db} ->
        CubDB.put(db, {:profile, source_path, timestamp}, profile)

      {:error, reason} ->
        Logger.error("Monitor: failed to save profile — #{inspect(reason)}")
    end
  end

  defp trim_profiles(source_path) do
    case PersistenceStore.get_db(source_path) do
      {:ok, db} ->
        profiles =
          Enum.to_list(CubDB.select(db,
            min_key: {:profile, source_path, ""},
            max_key: {:profile, source_path, "\xFF"},
            reverse: true
          ))

        if length(profiles) > @max_profiles do
          profiles
          |> Enum.drop(@max_profiles)
          |> Enum.each(fn {key, _} -> CubDB.delete(db, key) end)
        end

      {:error, _} ->
        :ok
    end
  end
end
