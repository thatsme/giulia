defmodule Giulia.Inference.Events do
  @moduledoc """
  Event broadcasting for the OODA loop.
  Allows clients to subscribe and receive real-time updates.
  """
  use GenServer

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Subscribe to events for a specific request"
  def subscribe(request_id) do
    GenServer.call(__MODULE__, {:subscribe, request_id, self()})
  end

  @doc "Unsubscribe from events"
  def unsubscribe(request_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, request_id, self()})
  end

  @doc "Broadcast an event to all subscribers"
  def broadcast(request_id, event) do
    GenServer.cast(__MODULE__, {:broadcast, request_id, event})
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_call({:subscribe, request_id, pid}, _from, state) do
    require Logger
    Logger.info("EVENTS: Subscribe #{inspect(pid)} to #{request_id}")
    subs = Map.get(state.subscriptions, request_id, [])
    new_subs = Map.put(state.subscriptions, request_id, [pid | subs])
    {:reply, :ok, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_cast({:unsubscribe, request_id, pid}, state) do
    subs = Map.get(state.subscriptions, request_id, [])
    new_subs = Map.put(state.subscriptions, request_id, List.delete(subs, pid))
    {:noreply, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_cast({:broadcast, request_id, event}, state) do
    require Logger
    subs = Map.get(state.subscriptions, request_id, [])
    Logger.info("EVENTS: Broadcasting #{inspect(event.type)} to #{length(subs)} subscribers for #{request_id}")
    Enum.each(subs, fn pid ->
      send(pid, {:ooda_event, event})
    end)
    {:noreply, state}
  end
end
