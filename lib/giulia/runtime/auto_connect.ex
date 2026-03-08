defmodule Giulia.Runtime.AutoConnect do
  @moduledoc """
  Auto-connect to a target BEAM node on startup.

  Reads `GIULIA_CONNECT_NODE` env var (e.g., `worker@giulia-worker`).
  If unset, returns `:ignore` from `init/1` — standalone and worker
  modes are completely unaffected.

  On successful connection, notifies the Collector to start watching
  the target node's runtime metrics.

  Retries with exponential backoff: 5s -> 10s -> 20s -> 40s -> cap 60s.
  """

  use GenServer

  require Logger

  @initial_retry_ms 5_000
  @max_retry_ms 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if connected to the target node."
  @spec connected?() :: boolean()
  def connected? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  @doc "Returns the target node atom, or nil if not configured."
  @spec target_node() :: atom() | nil
  def target_node do
    case GenServer.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :target_node)
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    case System.get_env("GIULIA_CONNECT_NODE") do
      nil ->
        :ignore

      "" ->
        :ignore

      node_str ->
        target = String.to_atom(node_str)
        Logger.info("AutoConnect: will connect to #{target}")

        state = %{
          target: target,
          connected: false,
          retry_ms: @initial_retry_ms
        }

        # Schedule first connection attempt
        Process.send_after(self(), :connect, @initial_retry_ms)

        {:ok, state}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call(:target_node, _from, state) do
    {:reply, state.target, state}
  end

  @impl true
  def handle_info(:connect, %{connected: true} = state) do
    # Already connected, no-op
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    cookie = System.get_env("GIULIA_COOKIE", "giulia_dev")

    case Giulia.Runtime.Inspector.connect(state.target, cookie: cookie) do
      :ok ->
        Logger.info("AutoConnect: connected to #{state.target}")

        # Tell the Collector to start watching the target node
        Giulia.Runtime.Collector.watch_node(state.target)

        {:noreply, %{state | connected: true, retry_ms: @initial_retry_ms}}

      {:error, reason} ->
        Logger.warning("AutoConnect: failed to connect to #{state.target}: #{inspect(reason)}, retrying in #{state.retry_ms}ms")

        # Schedule retry with exponential backoff
        Process.send_after(self(), :connect, state.retry_ms)
        next_retry = min(state.retry_ms * 2, @max_retry_ms)

        {:noreply, %{state | retry_ms: next_retry}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
