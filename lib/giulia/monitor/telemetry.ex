defmodule Giulia.Monitor.Telemetry do
  @moduledoc """
  Attaches `:telemetry` handlers for the Giulia daemon.

  Two handler groups:
  1. **HTTP Skin** — `[:giulia, :http, :start | :stop]` from `Plug.Telemetry`.
     Captures every REST call crossing the HTTP boundary: method, path,
     query params, status, duration, and response body (truncated at 5 KB).

  2. **Inference Pipeline** — 7 internal events from Engine + ToolDispatch.
     Captures inference lifecycle, LLM calls, tool executions.

  Build 95: Logic Monitor (inference events).
  Build 96: Global Logic Tap (HTTP skin events).
  """

  @max_response_size 5_000

  # Internal inference pipeline events
  @inference_events [
    [:giulia, :inference, :start],
    [:giulia, :inference, :step],
    [:giulia, :inference, :done],
    [:giulia, :llm, :call],
    [:giulia, :llm, :parsed],
    [:giulia, :tool, :start],
    [:giulia, :tool, :stop]
  ]

  # HTTP skin events (from Plug.Telemetry)
  @http_events [
    [:giulia, :http, :start],
    [:giulia, :http, :stop]
  ]

  @doc "Attach all telemetry handlers. Call once after supervisor starts."
  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many("giulia-monitor-inference", @inference_events, &handle_inference_event/4, nil)
    :telemetry.attach_many("giulia-monitor-http", @http_events, &handle_http_event/4, nil)
  end

  # ============================================================================
  # Inference Pipeline Handler (Build 95, renamed in Build 112)
  # ============================================================================

  @doc false
  def handle_inference_event(event_name, measurements, metadata, _config) do
    # Promote project_path to top-level `project` for dashboard filtering
    project = Map.get(metadata, :project_path) || Map.get(metadata, "project_path")

    Giulia.Monitor.Store.push(%{
      event: Enum.join(event_name, "."),
      measurements: measurements,
      metadata: Map.put(metadata, :project, project),
      timestamp: DateTime.utc_now()
    })
  end

  # ============================================================================
  # HTTP Skin Handler (Build 96)
  # ============================================================================

  @doc false
  # http.start carries no useful data — only http.stop has status, duration, body.
  def handle_http_event([:giulia, :http, :start], _measurements, _meta, _config), do: :ok

  def handle_http_event([:giulia, :http, :stop], measurements, %{conn: conn}, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration], :native, :millisecond)

    # Extract response body, safely truncate
    resp_body = extract_response_body(conn)

    # Extract project path from query params for scoping
    project = extract_project_param(conn)

    Giulia.Monitor.Store.push(%{
      event: "giulia.http.stop",
      measurements: %{duration_ms: duration_ms},
      metadata: %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string,
        status: conn.status,
        resp_body: resp_body,
        project: project
      },
      timestamp: DateTime.utc_now()
    })
  end

  def handle_http_event(_event, _measurements, _metadata, _config), do: :ok

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_project_param(conn) do
    case conn.query_string do
      "" -> nil
      qs ->
        qs
        |> URI.decode_query()
        |> Map.get("path")
    end
  rescue
    _ -> nil
  end

  defp extract_response_body(conn) do
    case conn.resp_body do
      nil -> nil
      body when is_binary(body) -> truncate(body, @max_response_size)
      body when is_list(body) ->
        body |> IO.iodata_to_binary() |> truncate(@max_response_size)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "... [truncated]"
end
