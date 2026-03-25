defmodule Giulia.Daemon.Routers.Monitor do
  @moduledoc """
  Routes for the Logic Monitor dashboard and SSE stream.

  Forwarded from `/api/monitor` — paths here are relative to that prefix.

  Build 95: Cognitive Flight Recorder.
  """

  use Giulia.Daemon.SkillRouter

  @sse_timeout 600_000

  # -------------------------------------------------------------------
  # GET /api/monitor — Serve the dashboard HTML
  # -------------------------------------------------------------------
  @skill %{
    intent: "Open the Logic Monitor dashboard (real-time inference telemetry)",
    endpoint: "GET /api/monitor",
    params: %{},
    returns: "HTML dashboard page",
    category: "monitor"
  }
  get "/" do
    serve_static(conn, "monitor.html")
  end

  # -------------------------------------------------------------------
  # GET /api/monitor/graph — Graph Explorer visualization
  # -------------------------------------------------------------------
  @skill %{
    intent: "Open the Graph Explorer (interactive dependency visualization with Cytoscape.js)",
    endpoint: "GET /api/monitor/graph",
    params: %{},
    returns: "HTML graph visualization page",
    category: "monitor"
  }
  get "/graph" do
    serve_static(conn, "graph.html")
  end

  # -------------------------------------------------------------------
  # GET /api/monitor/stream — SSE endpoint for real-time events
  # -------------------------------------------------------------------
  @skill %{
    intent: "Subscribe to real-time telemetry events via SSE",
    endpoint: "GET /api/monitor/stream",
    params: %{},
    returns: "Server-Sent Events stream of telemetry data",
    category: "monitor"
  }
  get "/stream" do
    Giulia.Monitor.Store.subscribe()

    conn = conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"status\":\"ok\"}\n\n")

    stream_monitor(conn)
  end

  # -------------------------------------------------------------------
  # GET /api/monitor/history — JSON: last N events from buffer
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get recent telemetry events from the monitor buffer",
    endpoint: "GET /api/monitor/history",
    params: %{n: :optional},
    returns: "JSON list of recent events",
    category: "monitor"
  }
  get "/history" do
    n = parse_int_param(conn.query_params["n"], 50)
    events = Giulia.Monitor.Store.history(n)

    serializable_events = Enum.map(events, &serialize_event/1)

    send_json(conn, 200, %{events: serializable_events, count: length(serializable_events)})
  end

  # -------------------------------------------------------------------
  # POST /api/monitor/observe/start — Start async observation
  # -------------------------------------------------------------------
  @skill %{
    intent: "Start observing a target BEAM node with optional module tracing",
    endpoint: "POST /api/monitor/observe/start",
    params: %{node: :required, cookie: :optional, worker_url: :optional, interval_ms: :optional, trace_modules: :optional},
    returns: "JSON confirmation with session_id, interval, and traced modules",
    category: "monitor"
  }
  post "/observe/start" do
    case Giulia.Runtime.Observer.start_observing(conn.body_params) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, error} when is_map(error) -> send_json(conn, 409, error)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # -------------------------------------------------------------------
  # POST /api/monitor/observe/stop — Stop observation, trigger finalize
  # -------------------------------------------------------------------
  @skill %{
    intent: "Stop observing a target node and trigger Worker finalization",
    endpoint: "POST /api/monitor/observe/stop",
    params: %{node: :optional},
    returns: "JSON summary with snapshots pushed, duration, and finalize result",
    category: "monitor"
  }
  post "/observe/stop" do
    case Giulia.Runtime.Observer.stop_observing(conn.body_params) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, error} when is_map(error) -> send_json(conn, 400, error)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # -------------------------------------------------------------------
  # GET /api/monitor/observe/status — Current observation state
  # -------------------------------------------------------------------
  @skill %{
    intent: "Check if an observation is currently running",
    endpoint: "GET /api/monitor/observe/status",
    params: %{},
    returns: "JSON status (idle or observing) with elapsed time and snapshot count",
    category: "monitor"
  }
  get "/observe/status" do
    status = Giulia.Runtime.Observer.observation_status()
    send_json(conn, 200, status)
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  # ============================================================================
  # SSE Streaming
  # ============================================================================

  defp stream_monitor(conn) do
    receive do
      {:monitor_event, event} ->
        data = Jason.encode!(serialize_event(event))
        case chunk(conn, "event: event\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_monitor(conn)
          {:error, _} ->
            Giulia.Monitor.Store.unsubscribe()
            conn
        end
    after
      @sse_timeout ->
        Giulia.Monitor.Store.unsubscribe()
        conn
    end
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  defp serialize_event(%{event: event, measurements: measurements, metadata: metadata, timestamp: timestamp}) do
    %{
      event: event,
      measurements: safe_encode(measurements),
      metadata: safe_encode(metadata),
      timestamp: to_string(timestamp)
    }
  end

  defp serialize_event(other), do: safe_encode(other)

  defp safe_encode(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, safe_encode_value(v)} end)
  end

  defp safe_encode(data) when is_tuple(data), do: inspect(data)
  defp safe_encode(data) when is_function(data), do: inspect(data)
  defp safe_encode(data) when is_pid(data), do: inspect(data)
  defp safe_encode(data) when is_reference(data), do: inspect(data)
  defp safe_encode(data), do: data

  defp serve_static(conn, filename) do
    html_path = Application.app_dir(:giulia, "priv/static/#{filename}")

    case File.read(html_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        send_json(conn, 500, %{error: "#{filename} not found"})
    end
  end

  defp safe_encode_value(v) when is_pid(v), do: inspect(v)
  defp safe_encode_value(v) when is_reference(v), do: inspect(v)
  defp safe_encode_value(v) when is_function(v), do: inspect(v)
  defp safe_encode_value(v) when is_tuple(v), do: inspect(v)
  defp safe_encode_value(v) when is_atom(v), do: to_string(v)
  defp safe_encode_value(v) when is_map(v), do: safe_encode(v)
  defp safe_encode_value(v) when is_list(v), do: Enum.map(v, &safe_encode_value/1)
  defp safe_encode_value(v), do: v
end
