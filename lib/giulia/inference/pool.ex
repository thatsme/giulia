defmodule Giulia.Inference.Pool do
  @moduledoc """
  Back-Pressure Pool for Inference Requests.

  The problem: A 4090 can only do one 32B inference effectively at a time.
  If users spam commands, we don't want to blow up LM Studio or hit rate limits.

  The solution: A simple GenServer-based queue per provider type.
  Requests queue in the BEAM (cheap), not crash the GPU (expensive).

  Architecture:
  - One pool per provider type (local_3b, local_32b, cloud)
  - FIFO queue for waiting requests
  - Automatic retry on transient failures
  - Timeout handling for stuck requests
  """
  use GenServer

  require Logger

  @type provider :: :local_3b | :local_32b | :cloud_sonnet
  @type request :: {pid(), reference(), String.t(), keyword()}

  defstruct [
    provider: nil,
    busy: false,
    current_request: nil,
    queue: :queue.new(),
    stats: %{
      total_requests: 0,
      completed: 0,
      failed: 0,
      timeouts: 0
    }
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Child spec that uses provider as the unique ID.
  """
  def child_spec(provider) do
    %{
      id: {__MODULE__, provider},
      start: {__MODULE__, :start_link, [provider]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Start a pool for a specific provider.
  """
  def start_link(provider) when provider in [:local_3b, :local_32b, :cloud_sonnet] do
    GenServer.start_link(__MODULE__, provider, name: via(provider))
  end

  @doc """
  Submit an inference request to the pool.
  Blocks until the result is ready or timeout.
  """
  @spec infer(provider(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def infer(provider, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    ref = make_ref()

    case GenServer.call(via(provider), {:enqueue, prompt, opts, ref}, timeout) do
      {:queued, ^ref} ->
        # Wait for result
        receive do
          {:inference_result, ^ref, result} -> result
        after
          timeout ->
            GenServer.cast(via(provider), {:cancel, ref})
            {:error, :timeout}
        end

      other ->
        other
    end
  end

  @doc """
  Get pool statistics.
  """
  @spec stats(provider()) :: map()
  def stats(provider) do
    GenServer.call(via(provider), :stats)
  end

  @doc """
  Get queue length.
  """
  @spec queue_length(provider()) :: non_neg_integer()
  def queue_length(provider) do
    GenServer.call(via(provider), :queue_length)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(provider) do
    Logger.info("Inference pool started for #{provider}")
    {:ok, %__MODULE__{provider: provider}}
  end

  @impl true
  def handle_call({:enqueue, prompt, opts, ref}, {from_pid, _}, state) do
    request = {from_pid, ref, prompt, opts}
    state = %{state | stats: %{state.stats | total_requests: state.stats.total_requests + 1}}

    if state.busy do
      # Queue the request
      queue = :queue.in(request, state.queue)
      Logger.debug("Request queued. Queue length: #{:queue.len(queue)}")
      {:reply, {:queued, ref}, %{state | queue: queue}}
    else
      # Process immediately
      {:reply, {:queued, ref}, start_inference(request, state)}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.merge(state.stats, %{
      queue_length: :queue.len(state.queue),
      busy: state.busy
    })
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:queue_length, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  @impl true
  def handle_cast({:cancel, ref}, state) do
    # Remove from queue if present
    queue = :queue.filter(fn {_, r, _, _} -> r != ref end, state.queue)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_info({:inference_complete, ref, result}, state) do
    # Send result to waiting process
    case state.current_request do
      {pid, ^ref, _, _} ->
        send(pid, {:inference_result, ref, result})
        state = update_stats(state, result)
        process_next(state)

      _ ->
        # Stale result, ignore
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, _, _}, state) do
    # Inference task crashed
    case state.current_request do
      {pid, ref, _, _} ->
        send(pid, {:inference_result, ref, {:error, :inference_crashed}})
        state = %{state | stats: %{state.stats | failed: state.stats.failed + 1}}
        process_next(state)

      _ ->
        {:noreply, state}
    end
  end

  # Handle Task.async results (they send back {ref, result} directly)
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Demonitor and flush to avoid getting a :DOWN message
    Process.demonitor(ref, [:flush])

    # Treat as inference complete
    case state.current_request do
      {pid, _req_ref, _, _} ->
        send(pid, {:inference_result, ref, result})
        state = update_stats(state, result)
        process_next(state)

      _ ->
        # Stale result, ignore
        {:noreply, state}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp via(provider) do
    {:via, Registry, {Giulia.Registry, {:inference_pool, provider}}}
  end

  defp start_inference({pid, ref, prompt, opts}, state) do
    Logger.debug("Starting inference for #{state.provider}")

    # Spawn a monitored task to do the actual inference
    pool_pid = self()
    task = Task.async(fn ->
      result = do_inference(state.provider, prompt, opts)
      send(pool_pid, {:inference_complete, ref, result})
      result
    end)

    Process.monitor(task.pid)

    %{state |
      busy: true,
      current_request: {pid, ref, prompt, opts}
    }
  end

  defp do_inference(provider, prompt, opts) do
    # Create a temporary orchestrator for this request
    project_path = Keyword.get(opts, :project_path)
    project_pid = Keyword.get(opts, :project_pid)

    {:ok, orchestrator} = Giulia.Inference.Orchestrator.start_link(
      project_path: project_path,
      project_pid: project_pid
    )

    try do
      Giulia.Inference.Orchestrator.execute(orchestrator, prompt, opts)
    after
      GenServer.stop(orchestrator, :normal, 1000)
    end
  end

  defp process_next(state) do
    case :queue.out(state.queue) do
      {{:value, request}, queue} ->
        Logger.debug("Processing next request from queue")
        {:noreply, start_inference(request, %{state | queue: queue})}

      {:empty, _} ->
        {:noreply, %{state | busy: false, current_request: nil}}
    end
  end

  defp update_stats(state, {:ok, _}) do
    %{state | stats: %{state.stats | completed: state.stats.completed + 1}}
  end

  defp update_stats(state, {:error, :timeout}) do
    %{state | stats: %{state.stats | timeouts: state.stats.timeouts + 1}}
  end

  defp update_stats(state, {:error, _}) do
    %{state | stats: %{state.stats | failed: state.stats.failed + 1}}
  end
end
