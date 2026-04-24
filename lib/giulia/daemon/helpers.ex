defmodule Giulia.Daemon.Helpers do
  @moduledoc """
  Shared helper functions for Giulia daemon routers.

  Extracted from Endpoint in Build 94 to be imported by sub-routers.
  """

  import Plug.Conn

  @doc "Send a JSON response with the given status code and data."
  @spec send_json(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  @doc "Resolve project path from ?path= query param. Returns nil if missing."
  @spec resolve_project_path(Plug.Conn.t()) :: String.t() | nil
  def resolve_project_path(conn) do
    case conn.query_params["path"] do
      nil -> nil
      path -> Giulia.Core.PathMapper.resolve_path(path)
    end
  end

  @doc "Parse ?node= param for runtime endpoints, default to :local."
  @spec parse_node_param(Plug.Conn.t()) :: atom()
  def parse_node_param(conn) do
    case conn.query_params["node"] do
      nil -> :local
      "" -> :local
      node_str -> safe_to_node_atom(node_str)
    end
  end

  @doc """
  Convert a node name string to an atom safely.

  Node names in Erlang must be atoms, but we validate the format
  (name@host) before conversion to prevent arbitrary atom creation
  from untrusted HTTP input.

  Prefers `String.to_existing_atom/1` so already-connected nodes
  reuse their existing atom. Falls back to `String.to_atom/1` only
  for new nodes that haven't been seen yet — this is unavoidable
  because Erlang node names must be atoms before a connection can
  be established.
  """
  @spec safe_to_node_atom(String.t()) :: atom()
  def safe_to_node_atom(node_str) when is_binary(node_str) do
    if Regex.match?(~r/^[a-zA-Z0-9_.\-]+@[a-zA-Z0-9_.\-]+$/, node_str) do
      try do
        String.to_existing_atom(node_str)
      rescue
        ArgumentError -> :erlang.binary_to_atom(node_str, :utf8)
      end
    else
      :local
    end
  end

  @doc "Format a behaviour fracture map for JSON output."
  @spec format_fracture(map()) :: map()
  def format_fracture(frac) do
    fmt = fn list -> Enum.map(list, fn {name, arity} -> "#{name}/#{arity}" end) end

    %{
      implementer: frac.implementer,
      missing: fmt.(Map.get(frac, :missing, [])),
      injected: fmt.(Map.get(frac, :injected, [])),
      optional_omitted: fmt.(Map.get(frac, :optional_omitted, [])),
      heuristic_injected: fmt.(Map.get(frac, :heuristic_injected, []))
    }
  end

  @doc "Parse an integer query param with a default fallback."
  @spec parse_int_param(String.t() | nil, integer()) :: integer()
  def parse_int_param(nil, default), do: default

  def parse_int_param(str, default) do
    case Integer.parse(to_string(str)) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc "Parse a float query param with a default fallback."
  @spec parse_float_param(String.t() | nil, float()) :: float()
  def parse_float_param(nil, default), do: default

  def parse_float_param(str, default) do
    case Float.parse(to_string(str)) do
      {f, _} -> f
      :error -> default
    end
  end

  # ============================================================================
  # Scan-state contract
  # ============================================================================

  @doc """
  Structured readiness signal for a project's scan state.

  Returns one of:
    * `:ready` — project has indexed AST data in L1 (file_count > 0, scan completed)
    * `{:pending, reason}` — a scan is in progress; client should poll
    * `{:not_indexed, reason}` — project has never been scanned, OR was scanned
      but found zero indexable files (`status: :empty`)

  Scan-dependent handlers use `require_scan_ready/2` to fail loud with
  `409 Conflict` + an actionable hint instead of silently returning
  `vertices=0 count=0 modules=[]` — the kind of ambiguous zero-result
  that makes LLM consumers spin without knowing the project isn't
  indexed.
  """
  @spec scan_state(String.t() | nil) ::
          :ready | {:pending, String.t()} | {:not_indexed, String.t()}
  def scan_state(nil), do: {:not_indexed, "missing :path param"}
  def scan_state(""), do: {:not_indexed, "empty :path param"}

  def scan_state(project_path) when is_binary(project_path) do
    case Giulia.Context.Indexer.status(project_path) do
      %{status: :scanning} ->
        {:pending, "scan in progress — poll GET /api/index/status?path=..."}

      %{status: :empty} ->
        {:not_indexed, "project was scanned but contained zero indexable files"}

      %{status: :idle, file_count: 0} ->
        {:not_indexed, "project has never been scanned"}

      %{status: :idle, file_count: n} when is_integer(n) and n > 0 ->
        :ready

      _ ->
        {:not_indexed, "scan state unknown"}
    end
  end

  @doc """
  Scan-state gate for a Plug handler. If the project is ready, returns
  `{:ok, conn}`. Otherwise returns `{:halt, conn}` with a `409 Conflict`
  already written to `conn` including the failure reason, the path that
  was checked, and a hint pointing the caller at the next action.

  Use via `with`:

      with {:ok, conn} <- require_scan_ready(conn, resolved_path) do
        # ... handler logic that assumes indexed data ...
      end

  The halt branch returns the already-responded conn so the caller can
  just fall through.
  """
  @doc """
  Combined gate used by most scan-dependent read handlers. Resolves
  `?path=` from the query string AND checks scan readiness in one pass.
  Returns `{:ok, conn, resolved_path}` when ready, or `{:halt, conn}`
  with an error response already written (400 for missing :path, 409
  for not-ready scan state).

  Idiomatic use:

      get "/stats" do
        case resolve_and_check_ready(conn) do
          {:halt, conn} ->
            conn

          {:ok, conn, project_path} ->
            # handler body using project_path; conn may be fresh
            send_json(conn, 200, ...)
        end
      end
  """
  @spec resolve_and_check_ready(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t(), String.t()} | {:halt, Plug.Conn.t()}
  def resolve_and_check_ready(conn) do
    case resolve_project_path(conn) do
      nil ->
        {:halt, send_json(conn, 400, %{error: "Missing required query param: path"})}

      project_path ->
        case require_scan_ready(conn, project_path) do
          {:ok, conn} -> {:ok, conn, project_path}
          {:halt, conn} -> {:halt, conn}
        end
    end
  end

  @spec require_scan_ready(Plug.Conn.t(), String.t() | nil) ::
          {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_scan_ready(conn, project_path) do
    case scan_state(project_path) do
      :ready ->
        {:ok, conn}

      {:pending, reason} ->
        {:halt,
         send_json(conn, 409, %{
           error: reason,
           path: project_path,
           state: "scan_in_progress",
           hint: "GET /api/index/status?path=... to poll until status=idle"
         })}

      {:not_indexed, reason} ->
        {:halt,
         send_json(conn, 409, %{
           error: reason,
           path: project_path,
           state: "not_indexed",
           hint: "POST /api/index/scan with this path first"
         })}
    end
  end
end
