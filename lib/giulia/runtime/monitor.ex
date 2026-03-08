defmodule Giulia.Runtime.Monitor do
  @moduledoc """
  Monitor Lifecycle Orchestrator.

  GenServer that manages the monitor's boot sequence and profile collection.
  Only starts in monitor mode (returns `:ignore` otherwise).

  ## Lifecycle

  1. **BOOT** — Trigger scan of Giulia's own source code, poll until done
  2. **CONNECT** — Wait for AutoConnect to establish distributed Erlang
  3. **WATCH** — Register as Collector's profile callback, enter idle
  4. **PROFILE** — Receive burst snapshots, produce profile via Profiler

  All transitions use `Process.send_after` — the GenServer stays responsive
  throughout (never blocks on a long scan or connection attempt).
  """

  use GenServer

  alias Giulia.Runtime.{AutoConnect, Collector, Profiler}

  require Logger

  @check_scan_interval 1_000
  @check_connect_interval 2_000
  @giulia_project_path "/projects/Giulia"
  @max_profiles 50

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current monitor phase and profile count."
  @spec status() :: map() | :not_running
  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> :not_running
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Returns the last N profiles, most recent first."
  @spec profiles(keyword()) :: list(map())
  def profiles(opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, {:profiles, opts})
    end
  end

  @doc "Returns the most recent profile, or nil."
  @spec latest_profile() :: map() | nil
  def latest_profile do
    case GenServer.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :latest_profile)
    end
  end

  @doc "Returns a specific profile by index (0 = most recent)."
  @spec get_profile(non_neg_integer()) :: map() | nil
  def get_profile(index) do
    case GenServer.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, {:get_profile, index})
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    unless Giulia.Role.monitor?() do
      :ignore
    else
      Logger.info("Monitor: starting lifecycle (BOOT phase)")

      state = %{
        phase: :boot,
        project_path: @giulia_project_path,
        profiles: [],
        boot_started_at: System.monotonic_time(:millisecond)
      }

      # Start boot: trigger scan of Giulia's own source
      Giulia.Context.Indexer.scan(@giulia_project_path)
      Process.send_after(self(), :check_scan, @check_scan_interval)

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      phase: state.phase,
      profile_count: length(state.profiles),
      project_path: state.project_path,
      uptime_ms: System.monotonic_time(:millisecond) - state.boot_started_at
    }

    {:reply, reply, state}
  end

  def handle_call({:profiles, opts}, _from, state) do
    last_n = Keyword.get(opts, :last, 10)
    {:reply, Enum.take(state.profiles, last_n), state}
  end

  def handle_call(:latest_profile, _from, state) do
    {:reply, List.first(state.profiles), state}
  end

  def handle_call({:get_profile, index}, _from, state) do
    {:reply, Enum.at(state.profiles, index), state}
  end

  # ============================================================================
  # Lifecycle Transitions
  # ============================================================================

  @impl true
  def handle_info(:check_scan, %{phase: :boot} = state) do
    case Giulia.Context.Indexer.status() do
      %{status: :idle} ->
        # Scan complete — check if we got modules
        modules = Giulia.Context.Store.list_modules(state.project_path)
        count = length(modules)

        if count > 0 do
          Logger.info("Monitor: BOOT complete — #{count} modules indexed. Moving to CONNECT phase.")
          Process.send_after(self(), :check_connect, @check_connect_interval)
          {:noreply, %{state | phase: :connect}}
        else
          # Scan finished but no modules — retry scan
          Logger.warning("Monitor: scan completed but 0 modules found. Retrying...")
          Giulia.Context.Indexer.scan(state.project_path)
          Process.send_after(self(), :check_scan, @check_scan_interval * 3)
          {:noreply, state}
        end

      _ ->
        # Still scanning
        Process.send_after(self(), :check_scan, @check_scan_interval)
        {:noreply, state}
    end
  end

  def handle_info(:check_connect, %{phase: :connect} = state) do
    if AutoConnect.connected?() do
      target = AutoConnect.target_node()
      Logger.info("Monitor: CONNECT complete — linked to #{target}. Moving to WATCH phase.")

      # Register ourselves as the Collector's profile callback
      Collector.set_profile_callback(self())

      {:noreply, %{state | phase: :watch}}
    else
      Process.send_after(self(), :check_connect, @check_connect_interval)
      {:noreply, state}
    end
  end

  # Profile delivery from Collector
  def handle_info({:profile_ready, node_ref, snapshots}, state) do
    Logger.info("Monitor: burst ended on #{node_ref} — #{length(snapshots)} snapshots. Generating profile...")

    profile = Profiler.produce(snapshots, state.project_path)
    profile = Map.put(profile, :node, to_string(node_ref))

    Logger.info("Monitor: profile generated — #{profile.duration_ms}ms burst, #{profile.peak_memory_mb}MB peak, #{length(profile.hot_modules)} hot modules")

    # Prepend (most recent first), cap at max
    profiles = [profile | state.profiles] |> Enum.take(@max_profiles)

    {:noreply, %{state | phase: :watch, profiles: profiles}}
  end

  # Ignore unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}
end
