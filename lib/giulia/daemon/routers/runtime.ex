defmodule Giulia.Daemon.Routers.Runtime do
  @moduledoc """
  Routes for runtime proprioception (BEAM introspection).

  Forwarded from `/api/runtime` — paths here are relative to that prefix.
  """

  use Giulia.Daemon.SkillRouter

  # -------------------------------------------------------------------
  # GET /api/runtime/pulse — BEAM health snapshot
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get BEAM health snapshot (memory, processes, schedulers, ETS)",
    endpoint: "GET /api/runtime/pulse",
    params: %{node: :optional},
    returns: "JSON pulse data with memory, process count, scheduler utilization",
    category: "runtime"
  }
  get "/pulse" do
    node_ref = parse_node_param(conn)

    case Giulia.Runtime.Inspector.pulse(node_ref) do
      {:ok, pulse} -> send_json(conn, 200, pulse)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/top_processes — Top 10 processes by metric
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get top 10 processes by metric (reductions, memory, message_queue)",
    endpoint: "GET /api/runtime/top_processes",
    params: %{metric: :optional, node: :optional},
    returns: "JSON list of top processes with PID, registered name, and metric value",
    category: "runtime"
  }
  get "/top_processes" do
    try do
      node_ref = parse_node_param(conn)
      metric = String.to_existing_atom(conn.query_params["metric"] || "reductions")

      case Giulia.Runtime.Inspector.top_processes(node_ref, metric) do
        {:ok, procs} -> send_json(conn, 200, %{processes: procs, count: length(procs), metric: metric})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    rescue
      ArgumentError -> send_json(conn, 400, %{error: "Invalid metric. Use: reductions, memory, message_queue"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/hot_spots — Top modules fused with Knowledge Graph
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get hot spots: top runtime modules fused with Knowledge Graph data",
    endpoint: "GET /api/runtime/hot_spots",
    params: %{path: :optional, node: :optional},
    returns: "JSON list of hot spot modules with runtime + static analysis data",
    category: "runtime"
  }
  get "/hot_spots" do
    node_ref = parse_node_param(conn)
    project_path = resolve_project_path(conn)

    case Giulia.Runtime.Inspector.hot_spots(node_ref, project_path) do
      {:ok, spots} -> send_json(conn, 200, %{hot_spots: spots, count: length(spots)})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/trace — Short-lived per-module function call trace
  # -------------------------------------------------------------------
  @skill %{
    intent: "Trace function calls for a module (short-lived)",
    endpoint: "GET /api/runtime/trace",
    params: %{module: :required, duration: :optional, node: :optional},
    returns: "JSON trace results with call counts",
    category: "runtime"
  }
  get "/trace" do
    node_ref = parse_node_param(conn)
    module = conn.query_params["module"]

    if module do
      duration = parse_int_param(conn.query_params["duration"], 5000)

      case Giulia.Runtime.Inspector.trace(node_ref, module, duration) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:unknown_module, m}} -> send_json(conn, 404, %{error: "Unknown module: #{m}"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required query param: module"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/history — Collector: last N snapshots
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get last N runtime snapshots from the collector",
    endpoint: "GET /api/runtime/history",
    params: %{last: :optional, node: :optional},
    returns: "JSON list of historical snapshots",
    category: "runtime"
  }
  get "/history" do
    node_ref = parse_node_param(conn)
    last_n = parse_int_param(conn.query_params["last"], 20)

    snapshots = Giulia.Runtime.Collector.history(node_ref, last: last_n)
    send_json(conn, 200, %{snapshots: snapshots, count: length(snapshots)})
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/trend — Collector: time-series for one metric
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get time-series trend for a runtime metric",
    endpoint: "GET /api/runtime/trend",
    params: %{metric: :optional, node: :optional},
    returns: "JSON time-series points for the requested metric",
    category: "runtime"
  }
  get "/trend" do
    try do
      node_ref = parse_node_param(conn)
      metric = String.to_existing_atom(conn.query_params["metric"] || "memory")

      points = Giulia.Runtime.Collector.trend(node_ref, metric)
      send_json(conn, 200, %{metric: metric, points: points, count: length(points)})
    rescue
      ArgumentError -> send_json(conn, 400, %{error: "Invalid metric. Use: memory, processes, run_queue, ets_memory"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/alerts — Collector: active warnings
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get active runtime alerts with duration",
    endpoint: "GET /api/runtime/alerts",
    params: %{node: :optional},
    returns: "JSON list of active alerts",
    category: "runtime"
  }
  get "/alerts" do
    node_ref = parse_node_param(conn)

    alerts = Giulia.Runtime.Collector.alerts(node_ref)
    send_json(conn, 200, %{alerts: alerts, count: length(alerts)})
  end

  # -------------------------------------------------------------------
  # POST /api/runtime/connect — Connect to a remote BEAM node
  # -------------------------------------------------------------------
  @skill %{
    intent: "Connect to a remote BEAM node for introspection",
    endpoint: "POST /api/runtime/connect",
    params: %{node: :required, cookie: :optional},
    returns: "JSON confirmation of connection or error",
    category: "runtime"
  }
  post "/connect" do
    node_name = conn.body_params["node"]
    cookie = conn.body_params["cookie"]

    if node_name do
      node_atom = String.to_atom(node_name)
      opts = if cookie, do: [cookie: cookie], else: []

      case Giulia.Runtime.Inspector.connect(node_atom, opts) do
        :ok -> send_json(conn, 200, %{status: "connected", node: node_name})
        {:error, reason} -> send_json(conn, 422, %{error: inspect(reason), node: node_name})
      end
    else
      send_json(conn, 400, %{error: "Missing required field: node"})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/profiles — List saved burst profiles
  # -------------------------------------------------------------------
  @skill %{
    intent: "List saved burst performance profiles from the monitor",
    endpoint: "GET /api/runtime/profiles",
    params: %{last: :optional},
    returns: "JSON list of profiles with peak metrics, hot modules, bottleneck analysis",
    category: "runtime"
  }
  get "/profiles" do
    last_n = parse_int_param(conn.query_params["last"], 10)
    profiles = Giulia.Runtime.Monitor.profiles(last: last_n)
    send_json(conn, 200, %{profiles: profiles, count: length(profiles)})
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/profile/latest — Most recent burst profile
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get the most recent burst performance profile",
    endpoint: "GET /api/runtime/profile/latest",
    params: %{},
    returns: "JSON profile with peak metrics, hot modules, bottleneck analysis (or null)",
    category: "runtime"
  }
  get "/profile/latest" do
    case Giulia.Runtime.Monitor.latest_profile() do
      nil -> send_json(conn, 200, %{profile: nil, message: "No profiles captured yet"})
      profile -> send_json(conn, 200, %{profile: profile})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/runtime/profile/:id — Profile by index (0 = most recent)
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get a specific burst profile by index (0 = most recent)",
    endpoint: "GET /api/runtime/profile/:id",
    params: %{id: :required},
    returns: "JSON profile or 404 if not found",
    category: "runtime"
  }
  get "/profile/:id" do
    index = parse_int_param(id, 0)

    case Giulia.Runtime.Monitor.get_profile(index) do
      nil -> send_json(conn, 404, %{error: "Profile not found at index #{index}"})
      profile -> send_json(conn, 200, %{profile: profile})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end
end
