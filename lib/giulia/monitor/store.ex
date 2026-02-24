defmodule Giulia.Monitor.Store do
  @moduledoc """
  Rolling buffer of telemetry events with SSE pub/sub.

  Maintains a bounded queue of the last @max_events events and fans out
  new events to SSE subscribers in real-time. Zero overhead when nobody
  is watching — the buffer fills silently and SSE fan-out is a no-op on
  an empty subscriber set.

  Build 95: Logic Monitor.
  """

  use GenServer

  @max_events 50

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push a telemetry event into the buffer and fan out to SSE subscribers."
  def push(event) do
    GenServer.cast(__MODULE__, {:push, event})
  end

  @doc "Return the last `n` events (default: all in buffer)."
  def history(n \\ @max_events) do
    GenServer.call(__MODULE__, {:history, n})
  end

  @doc "Subscribe the calling process to receive `{:monitor_event, event}` messages."
  def subscribe do
    GenServer.call(__MODULE__, :subscribe)
  end

  @doc "Unsubscribe the calling process."
  def unsubscribe do
    GenServer.cast(__MODULE__, {:unsubscribe, self()})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{
      buffer: :queue.new(),
      buffer_size: 0,
      max_size: @max_events,
      subscribers: MapSet.new()
    }}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    # Enqueue and trim
    buffer = :queue.in(event, state.buffer)
    {buffer, size} =
      if state.buffer_size >= state.max_size do
        {{:value, _}, trimmed} = :queue.out(buffer)
        {trimmed, state.buffer_size}
      else
        {buffer, state.buffer_size + 1}
      end

    # Fan out to SSE subscribers
    for pid <- state.subscribers do
      send(pid, {:monitor_event, event})
    end

    {:noreply, %{state | buffer: buffer, buffer_size: size}}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_call({:history, n}, _from, state) do
    events =
      state.buffer
      |> :queue.to_list()
      |> Enum.take(-n)

    {:reply, events, state}
  end

  def handle_call(:subscribe, {pid, _ref}, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
