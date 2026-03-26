defmodule Giulia.Runtime.Observer do
  @moduledoc """
  Observation Controller — Build 135.

  Manages async observation sessions driven by external command (start/stop).
  When started, connects to the target BEAM node, collects runtime snapshots
  at a configurable interval, and pushes each snapshot to the Worker via HTTP.

  ## Design

  Claude Code (or the `giulia-observe.bat` script) controls the lifecycle:

      start → collect every N ms → stop → finalize on Worker

  The observation window is determined by the external workload (e.g., integration
  tests running against the target), not by a timer. This is intentionally async —
  nothing interesting happens on the target until the tests start.

  ## Single Observer

  Only one observation can be active at a time. Starting a new observation while
  one is running will return an error. Stop the current one first.
  """

  use GenServer

  alias Giulia.Runtime.Inspector
  alias Giulia.Runtime.Inspector.Trace

  require Logger

  @default_interval_ms 5_000

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start observing a target node. Connects and begins pushing snapshots to Worker.
  """
  @spec start_observing(map()) :: {:ok, map()} | {:error, term()}
  def start_observing(params) do
    GenServer.call(__MODULE__, {:start_observing, params})
  end

  @doc """
  Stop the current observation. Sends finalize to Worker.
  """
  @spec stop_observing(map()) :: {:ok, map()} | {:error, term()}
  def stop_observing(params) do
    GenServer.call(__MODULE__, {:stop_observing, params}, 15_000)
  end

  @doc """
  Get the current observation status.
  """
  @spec observation_status() :: map()
  def observation_status do
    GenServer.call(__MODULE__, :status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      status: :idle,
      node: nil,
      worker_url: nil,
      interval_ms: @default_interval_ms,
      trace_modules: [],
      started_at: nil,
      session_id: nil,
      snapshots_pushed: 0,
      last_observation: nil,
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_observing, _params}, _from, %{status: :observing} = state) do
    {:reply,
     {:error,
      %{
        error: "already_observing",
        node: state.node,
        started_at: state.started_at,
        detail: "Stop current observation first"
      }}, state}
  end

  def handle_call({:start_observing, params}, _from, state) do
    node_str = params["node"]
    cookie = params["cookie"]
    worker_url = params["worker_url"] || "http://giulia-worker:4000"
    interval_ms = params["interval_ms"] || @default_interval_ms
    trace_modules = params["trace_modules"] || []

    unless node_str do
      {:reply, {:error, %{error: "missing_node", detail: "node field is required"}}, state}
    else
      node_atom = Giulia.Daemon.Helpers.safe_to_node_atom(node_str)

      # Connect to target node
      connect_opts = if cookie, do: [cookie: cookie], else: []

      case Inspector.connect(node_atom, connect_opts) do
        :ok ->
          now = DateTime.to_iso8601(DateTime.utc_now())
          session_id = "obs_" <> String.replace(now, ~r/[^0-9]/, "")

          trace_label =
            if trace_modules != [], do: ", tracing: #{inspect(trace_modules)}", else: ""

          Logger.info(
            "Observer: started observing #{node_str} (session: #{session_id}, interval: #{interval_ms}ms#{trace_label})"
          )

          # Schedule first collection
          timer_ref = Process.send_after(self(), :collect, interval_ms)

          new_state = %{
            state
            | status: :observing,
              node: node_str,
              worker_url: worker_url,
              interval_ms: interval_ms,
              trace_modules: trace_modules,
              started_at: now,
              session_id: session_id,
              snapshots_pushed: 0,
              timer_ref: timer_ref
          }

          reply = %{
            status: "observing",
            node: node_str,
            session_id: session_id,
            interval_ms: interval_ms,
            trace_modules: trace_modules,
            started_at: now
          }

          {:reply, {:ok, reply}, new_state}

        {:error, reason} ->
          {:reply,
           {:error,
            %{
              error: "connection_failed",
              node: node_str,
              detail: inspect(reason)
            }}, state}
      end
    end
  end

  def handle_call({:stop_observing, _params}, _from, %{status: :idle} = state) do
    {:reply, {:error, %{error: "not_observing", detail: "No observation is active"}}, state}
  end

  def handle_call({:stop_observing, _params}, _from, state) do
    # Cancel the collection timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    now = DateTime.to_iso8601(DateTime.utc_now())

    Logger.info(
      "Observer: stopping observation of #{state.node} (#{state.snapshots_pushed} snapshots)"
    )

    # Send finalize to Worker
    finalize_result = send_finalize(state, now)

    last_observation = %{
      node: state.node,
      session_id: state.session_id,
      started_at: state.started_at,
      stopped_at: now,
      snapshots_pushed: state.snapshots_pushed,
      trace_modules: state.trace_modules
    }

    reply = %{
      status: "stopped",
      node: state.node,
      session_id: state.session_id,
      started_at: state.started_at,
      stopped_at: now,
      snapshots_pushed: state.snapshots_pushed,
      finalize: finalize_result
    }

    new_state = %{
      state
      | status: :idle,
        node: nil,
        worker_url: nil,
        trace_modules: [],
        started_at: nil,
        session_id: nil,
        snapshots_pushed: 0,
        timer_ref: nil,
        last_observation: last_observation
    }

    {:reply, {:ok, reply}, new_state}
  end

  def handle_call(:status, _from, state) do
    reply =
      case state.status do
        :observing ->
          elapsed = elapsed_seconds(state.started_at)

          %{
            status: "observing",
            node: state.node,
            session_id: state.session_id,
            started_at: state.started_at,
            snapshots_pushed: state.snapshots_pushed,
            trace_modules: state.trace_modules,
            elapsed_seconds: elapsed
          }

        :idle ->
          base = %{status: "idle"}

          if state.last_observation do
            Map.put(base, :last_observation, state.last_observation)
          else
            base
          end
      end

    {:reply, reply, state}
  end

  # ============================================================================
  # Collection Loop
  # ============================================================================

  @impl true
  def handle_info(:collect, %{status: :observing} = state) do
    node_atom = Giulia.Daemon.Helpers.safe_to_node_atom(state.node)

    # Collect pulse + top processes
    snapshot = collect_snapshot(node_atom)

    # Collect trace data for specified modules (async, bounded)
    trace_data = collect_traces(node_atom, state.trace_modules, state.interval_ms)
    snapshot = Map.put(snapshot, :trace_calls, trace_data)

    # Push to Worker
    pushed = push_snapshot(state.worker_url, state.session_id, state.node, snapshot)

    count = if pushed, do: state.snapshots_pushed + 1, else: state.snapshots_pushed

    # Schedule next collection
    timer_ref = Process.send_after(self(), :collect, state.interval_ms)

    {:noreply, %{state | snapshots_pushed: count, timer_ref: timer_ref}}
  end

  def handle_info(:collect, state) do
    # Not observing anymore, ignore stale timer
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Trace Collection
  # ============================================================================

  defp collect_traces(_node_atom, [], _interval_ms), do: []

  defp collect_traces(node_atom, modules, interval_ms) do
    # Cap trace duration: 2s per module or (interval - 1s) / num_modules
    max_per_module = min(2_000, div(max(interval_ms - 1_000, 500), length(modules)))

    tasks =
      Enum.map(modules, fn mod ->
        Task.async(fn ->
          case Trace.run_remote(node_atom, mod, max_per_module) do
            {:ok, result} -> {:ok, mod, result}
            {:error, reason} -> {:error, mod, reason}
          end
        end)
      end)

    timeout = max(min(interval_ms - 500, 5_000), 1_000)

    Enum.flat_map(Task.yield_many(tasks, timeout), fn
      {_task, {:ok, {:ok, _mod, result}}} ->
        Enum.map(result.calls, fn call ->
          %{
            module: result.module,
            function: call["function"] || call[:function],
            arity: call["arity"] || call[:arity],
            call_count: call["count"] || call[:count] || 0
          }
        end)

      {_task, {:ok, {:error, mod, reason}}} ->
        Logger.warning("Observer: trace failed for #{mod} — #{inspect(reason)}")
        []

      {task, nil} ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("Observer: trace timeout")
        []

      _ ->
        []
    end)
  end

  # ============================================================================
  # Snapshot Collection
  # ============================================================================

  defp collect_snapshot(node_atom) do
    pulse_data =
      case Inspector.pulse(node_atom) do
        {:ok, pulse} -> pulse
        _ -> %{}
      end

    top_procs =
      case Inspector.top_processes(node_atom, :reductions) do
        {:ok, procs} -> Enum.take(procs, 10)
        _ -> []
      end

    beam = pulse_data[:beam] || %{}

    %{
      metrics: %{
        process_count: beam[:processes] || 0,
        memory_mb: beam[:memory_mb] || 0,
        atom_count: 0,
        ets_tables: get_in(pulse_data, [:ets, :tables]) || 0,
        message_queue_total: 0,
        reductions_per_sec: beam[:reductions] || 0,
        schedulers_online: beam[:schedulers] || 0,
        run_queue: beam[:run_queue] || 0
      },
      hot_processes:
        Enum.map(top_procs, fn p ->
          %{
            pid: p[:pid],
            module: p[:module],
            reductions: p[:reductions] || p[:metric_value] || 0,
            memory_kb: p[:memory_kb] || 0,
            message_queue: p[:message_queue] || 0
          }
        end),
      ets_snapshot: get_in(pulse_data, [:ets, :god_tables]) || []
    }
  end

  # ============================================================================
  # HTTP Push to Worker
  # ============================================================================

  defp push_snapshot(worker_url, session_id, node, snapshot) do
    url = "#{worker_url}/api/runtime/ingest"
    timestamp = DateTime.to_iso8601(DateTime.utc_now())

    body =
      Map.merge(snapshot, %{
        node: node,
        session_id: session_id,
        timestamp: timestamp
      })

    case http_post(url, body) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Observer: failed to push snapshot — #{inspect(reason)}")
        false
    end
  end

  defp send_finalize(state, stopped_at) do
    url = "#{state.worker_url}/api/runtime/ingest/finalize"

    body = %{
      session_id: state.session_id,
      node: state.node,
      started_at: state.started_at,
      stopped_at: stopped_at,
      total_snapshots: state.snapshots_pushed
    }

    case http_post(url, body) do
      {:ok, response} ->
        response

      {:error, reason} ->
        Logger.error("Observer: finalize failed — #{inspect(reason)}")
        %{error: inspect(reason)}
    end
  end

  defp http_post(url, body) do
    case Req.post(url, json: body, receive_timeout: 15_000) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, exception} ->
        {:error, {:request_failed, Exception.message(exception)}}
    end
  rescue
    e -> {:error, {:request_failed, Exception.message(e)}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp elapsed_seconds(nil), do: 0

  defp elapsed_seconds(started_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :second)
      _ -> 0
    end
  end
end
