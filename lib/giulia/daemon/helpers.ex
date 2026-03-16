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
  """
  @spec safe_to_node_atom(String.t()) :: atom()
  def safe_to_node_atom(node_str) when is_binary(node_str) do
    if Regex.match?(~r/^[a-zA-Z0-9_.\-]+@[a-zA-Z0-9_.\-]+$/, node_str) do
      String.to_atom(node_str)
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
end
