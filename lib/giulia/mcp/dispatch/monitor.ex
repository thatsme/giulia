defmodule Giulia.MCP.Dispatch.Monitor do
  @moduledoc """
  MCP dispatch handlers for the `monitor_*` tool family (MCP-compatible
  subset only — HTML and SSE-stream Monitor endpoints are filtered by
  `Giulia.MCP.ToolSchema.mcp_compatible?/1`).
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Monitor.Store
  alias Giulia.Runtime.Observer

  @spec history(map()) :: {:ok, map()}
  def history(args) do
    n = parse_int(args["n"], 50)
    events = Store.history(n)
    {:ok, %{events: events, count: length(events)}}
  end

  @spec observe_start(map()) :: {:ok, term()} | {:error, String.t()}
  def observe_start(args) do
    case Observer.start_observing(args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec observe_stop(map()) :: {:ok, term()} | {:error, String.t()}
  def observe_stop(args) do
    case Observer.stop_observing(args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec observe_status(map()) :: {:ok, term()}
  def observe_status(_args) do
    {:ok, Observer.observation_status()}
  end
end
