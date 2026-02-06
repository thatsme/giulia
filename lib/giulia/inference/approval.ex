defmodule Giulia.Inference.Approval do
  @moduledoc """
  Interactive Consent Gate - Manages approval requests for dangerous operations.

  When the orchestrator wants to write/edit files, it requests approval here.
  Supports both blocking (for simple use cases) and async (for orchestrator) modes.

  Async Flow (recommended for orchestrator):
  1. Orchestrator calls request_approval_async/6 - returns immediately
  2. Orchestrator enters :waiting_for_approval state
  3. User responds via HTTP endpoint, calls respond/2
  4. Approval sends {:approval_response, approval_id, result} to callback_pid
  5. Orchestrator receives message in handle_info, continues

  Blocking Flow (for simple cases):
  1. Caller calls request_approval/5 - blocks
  2. HTTP endpoint receives user decision, calls respond/2
  3. request_approval returns with :approved, :rejected, or :timeout

  This GenServer maintains a map of pending approval requests.
  """
  use GenServer

  require Logger

  @default_timeout 300_000  # 5 minutes

  defstruct pending: %{}  # request_id => %{from: GenServer.from() | {:async, pid}, tool: string, ...}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request approval asynchronously (NON-BLOCKING).

  Returns :ok immediately. When the user responds (or timeout),
  sends `{:approval_response, approval_id, result}` to callback_pid.

  Result will be:
  - :approved - User approved the operation
  - :rejected - User rejected the operation
  - {:timeout, reason} - Timed out waiting for response

  This is the preferred method for the orchestrator to avoid deadlock.
  """
  def request_approval_async(approval_id, tool, params, preview, callback_pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.cast(__MODULE__, {:request_approval_async, approval_id, tool, params, preview, callback_pid, timeout})
  end

  @doc """
  Request approval for a dangerous operation (BLOCKING).

  Blocks until user responds or timeout.
  WARNING: Do not use from GenServer callbacks - use request_approval_async instead.

  Returns:
  - :approved - User approved the operation
  - :rejected - User rejected the operation
  - {:timeout, reason} - Timed out waiting for response
  """
  def request_approval(request_id, tool, params, preview, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(__MODULE__, {:request_approval, request_id, tool, params, preview, timeout}, timeout + 5000)
  end

  @doc """
  Respond to a pending approval request.

  Called by HTTP endpoint when user decides.
  """
  def respond(request_id, approved?) do
    GenServer.cast(__MODULE__, {:respond, request_id, approved?})
  end

  @doc """
  Get info about a pending approval request.
  """
  def get_pending(request_id) do
    GenServer.call(__MODULE__, {:get_pending, request_id})
  end

  @doc """
  List all pending approval requests.
  """
  def list_pending do
    GenServer.call(__MODULE__, :list_pending)
  end

  @doc """
  Cancel a pending approval request.
  """
  def cancel(request_id) do
    GenServer.cast(__MODULE__, {:cancel, request_id})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup of expired requests
    schedule_cleanup()
    {:ok, %__MODULE__{}}
  end

  # ============================================================================
  # handle_call implementations (grouped together)
  # ============================================================================

  @impl true
  def handle_call({:request_approval, request_id, tool, params, preview, timeout}, from, state) do
    Logger.info("Approval requested (blocking) for #{tool}: #{request_id}")

    expires_at = DateTime.add(DateTime.utc_now(), timeout, :millisecond)

    pending_request = %{
      from: {:sync, from},
      tool: tool,
      params: params,
      preview: preview,
      expires_at: expires_at,
      requested_at: DateTime.utc_now()
    }

    new_pending = Map.put(state.pending, request_id, pending_request)

    # Schedule timeout
    Process.send_after(self(), {:timeout, request_id}, timeout)

    # Don't reply yet - we'll reply when user responds or timeout
    {:noreply, %{state | pending: new_pending}}
  end

  @impl true
  def handle_call({:get_pending, request_id}, _from, state) do
    case Map.get(state.pending, request_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      request ->
        info = %{
          tool: request.tool,
          params: request.params,
          preview: request.preview,
          requested_at: request.requested_at,
          expires_at: request.expires_at
        }
        {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    pending_list = state.pending
    |> Enum.map(fn {id, req} ->
      %{
        request_id: id,
        tool: req.tool,
        requested_at: req.requested_at,
        expires_at: req.expires_at
      }
    end)

    {:reply, pending_list, state}
  end

  # ============================================================================
  # handle_cast implementations (grouped together)
  # ============================================================================

  # Async approval request handler
  @impl true
  def handle_cast({:request_approval_async, approval_id, tool, params, preview, callback_pid, timeout}, state) do
    Logger.info("Approval requested (async) for #{tool}: #{approval_id}")

    expires_at = DateTime.add(DateTime.utc_now(), timeout, :millisecond)

    pending_request = %{
      from: {:async, callback_pid},
      tool: tool,
      params: params,
      preview: preview,
      expires_at: expires_at,
      requested_at: DateTime.utc_now()
    }

    new_pending = Map.put(state.pending, approval_id, pending_request)

    # Schedule timeout
    Process.send_after(self(), {:timeout, approval_id}, timeout)

    {:noreply, %{state | pending: new_pending}}
  end

  @impl true
  def handle_cast({:respond, request_id, approved?}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        Logger.warning("Approval response for unknown request: #{request_id}")
        {:noreply, state}

      {request, new_pending} ->
        result = if approved?, do: :approved, else: :rejected
        Logger.info("Approval #{result} for #{request.tool}: #{request_id}")

        # Reply based on how the request was made
        reply_to_requester(request.from, request_id, result)

        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_cast({:cancel, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {request, new_pending} ->
        reply_to_requester(request.from, request_id, {:timeout, :cancelled})
        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        # Already responded, ignore
        {:noreply, state}

      {request, new_pending} ->
        Logger.warning("Approval timeout for #{request.tool}: #{request_id}")
        reply_to_requester(request.from, request_id, {:timeout, :deadline_exceeded})
        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = DateTime.utc_now()

    {expired, valid} = state.pending
    |> Enum.split_with(fn {_id, req} ->
      DateTime.compare(req.expires_at, now) == :lt
    end)

    # Timeout expired requests
    Enum.each(expired, fn {request_id, request} ->
      Logger.warning("Cleaning up expired approval: #{request_id}")
      reply_to_requester(request.from, request_id, {:timeout, :expired})
    end)

    schedule_cleanup()
    {:noreply, %{state | pending: Map.new(valid)}}
  end

  # Reply based on how the request was made (sync vs async)
  defp reply_to_requester({:sync, from}, _approval_id, result) do
    GenServer.reply(from, result)
  end

  defp reply_to_requester({:async, pid}, approval_id, result) do
    send(pid, {:approval_response, approval_id, result})
  end

  defp schedule_cleanup do
    # Check for expired requests every 30 seconds
    Process.send_after(self(), :cleanup_expired, 30_000)
  end
end
