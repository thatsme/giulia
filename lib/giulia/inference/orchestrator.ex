defmodule Giulia.Inference.Orchestrator do
  @moduledoc """
  Thin GenServer shell for the Inference Loop State Machine.

  All control flow has been extracted to focused modules (build 84):
  - `Engine`        — Inference loop core, provider calls, response routing
  - `ToolDispatch`  — Tool execution, staging, approval gating
  - `ContextBuilder`— Messages, previews, interventions, hub risk

  The Orchestrator's ONLY job is translating OTP messages to Engine.dispatch
  calls and directives back to GenServer tuples.

  Directive pattern:
    {:next, action, state}  → {:noreply, state, {:continue, action}}
    {:done, result, state}  → send_reply + reset_state
    {:halt, state}          → {:noreply, state}
  """
  use GenServer

  require Logger

  alias Giulia.Core.ProjectContext
  alias Giulia.Inference.{Engine, State, ToolDispatch, Trace, Transaction}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute synchronously. Blocks until the inference loop completes.
  """
  def execute(orchestrator, prompt, opts \\ []) do
    # 10-minute timeout — the inference loop can run many iterations
    GenServer.call(orchestrator, {:execute, prompt, opts}, 600_000)
  end

  @doc """
  Execute asynchronously. Returns immediately, sends result via message.
  """
  def execute_async(orchestrator, prompt, opts \\ []) do
    GenServer.cast(orchestrator, {:execute_async, prompt, opts, self()})
  end

  @doc """
  Get current state (for debugging/monitoring).
  """
  def get_state(orchestrator) do
    GenServer.call(orchestrator, :get_state)
  end

  @doc """
  Cancel the current task.
  """
  def cancel(orchestrator) do
    GenServer.cast(orchestrator, :cancel)
  end

  @doc """
  Pause the thinking loop (can resume later).
  """
  def pause(orchestrator) do
    GenServer.cast(orchestrator, :pause)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    project_pid = Keyword.get(opts, :project_pid)

    # Read transaction preference from ProjectContext if available
    transaction_pref =
      if project_pid do
        try do
          ProjectContext.transaction_preference(project_pid)
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      else
        false
      end

    state = State.new(
      project_path: Keyword.get(opts, :project_path),
      project_pid: project_pid,
      transaction: Transaction.new(transaction_pref)
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, prompt, opts}, from, state) do
    request_id = Keyword.get(opts, :request_id, make_ref() |> inspect())
    state = state |> State.set_task(prompt) |> State.set_reply_to(from) |> State.set_status(:starting) |> State.set_request_id(request_id)
    {:noreply, state, {:continue, {:start, prompt, opts}}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:execute_async, prompt, opts, reply_pid}, state) do
    state = state |> State.set_task(prompt) |> State.set_reply_to({:async, reply_pid}) |> State.set_status(:starting)
    {:noreply, state, {:continue, {:start, prompt, opts}}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Orchestrator cancelled")
    send_reply(state, {:error, :cancelled})
    {:noreply, reset_state(state)}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Orchestrator paused at iteration #{State.iteration(state)}")
    {:noreply, State.set_status(state, :paused)}
  end

  # ============================================================================
  # Async Approval Response Handler
  # ============================================================================

  @impl true
  def handle_info({:approval_response, approval_id, result}, state) do
    case state.pending_approval do
      %{approval_id: ^approval_id} = pending ->
        Logger.info("Received approval response for #{pending.tool}: #{inspect(result)}")

        # Clear pending approval state
        state = state |> State.clear_pending_approval() |> State.set_status(:thinking)

        ToolDispatch.handle_approval_response(result, pending, state)
        |> apply_directive()

      _ ->
        # Stale or mismatched approval response, ignore
        Logger.warning("Received approval response for unknown/stale request: #{approval_id}")
        {:noreply, state}
    end
  end

  # ============================================================================
  # The Universal Dispatcher
  # ============================================================================

  @impl true
  def handle_continue(action, state) do
    Engine.dispatch(action, state) |> apply_directive()
  end

  # ============================================================================
  # Directive → GenServer Tuple
  # ============================================================================

  defp apply_directive({:next, action, state}) do
    {:noreply, state, {:continue, action}}
  end

  defp apply_directive({:done, result, state}) do
    send_reply(state, result)
    {:noreply, reset_state(state)}
  end

  defp apply_directive({:halt, state}) do
    {:noreply, state}
  end

  # ============================================================================
  # GenServer-Coupled Helpers (the ONLY place that knows about GenServer.reply)
  # ============================================================================

  defp send_reply(%{reply_to: nil}, _result), do: :ok

  defp send_reply(%{reply_to: {:async, pid}}, result) do
    send(pid, {:orchestrator_result, result})
  end

  defp send_reply(%{reply_to: from}, result) do
    GenServer.reply(from, result)
  end

  defp reset_state(state) do
    # Save trace before resetting (for debugging via /api/agent/last_trace)
    if state.task do
      trace = Trace.from_orchestrator_state(state)
      Trace.store(trace)
    end

    State.reset(state)
  end
end
