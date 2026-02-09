defmodule Giulia.Inference.State do
  @moduledoc """
  Pure-functional state management for the Orchestrator.

  Provides:
  - `@type t` with grouped sub-types (counters, provider, verification, goal)
  - ~30 pure functions that take `%State{}` and return `%State{}`
  - Zero GenServer coupling — all functions are deterministic

  Extracted from Orchestrator (build 83) to establish a typed contract
  and eliminate 55 inline `%{state | ...}` mutations.
  """

  alias Giulia.Inference.Transaction

  # ============================================================================
  # Sub-Type Definitions
  # ============================================================================

  @type counters :: %{
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          consecutive_failures: non_neg_integer(),
          max_failures: pos_integer(),
          repeat_count: non_neg_integer(),
          syntax_failures: non_neg_integer(),
          goal_tracker_blocks: non_neg_integer()
        }

  @type provider_state :: %{
          name: String.t() | atom() | nil,
          module: module() | nil,
          escalated: boolean(),
          original: String.t() | atom() | nil,
          last_compile_error: String.t() | nil
        }

  @type verification :: %{
          pending: boolean(),
          test_status: :untested | :red | :green,
          baseline: :clean | :dirty | :unknown
        }

  @type goal :: %{
          last_impact_map: map() | nil,
          modified_files: MapSet.t()
        }

  # ============================================================================
  # Main Struct
  # ============================================================================

  @type t :: %__MODULE__{
          task: String.t() | nil,
          project_path: String.t() | nil,
          project_pid: pid() | nil,
          reply_to: {pid(), reference()} | {:async, pid()} | nil,
          request_id: String.t() | nil,
          status: :idle | :starting | :thinking | :waiting_for_approval | :paused,
          messages: list(),
          last_action: {String.t(), map()} | nil,
          action_history: list(),
          recent_errors: list(),
          final_response: String.t() | nil,
          counters: counters(),
          provider: provider_state(),
          verification: verification(),
          goal: goal(),
          pending_tool_calls: list(),
          pending_approval: map() | nil,
          transaction: Transaction.t()
        }

  defstruct task: nil,
            project_path: nil,
            project_pid: nil,
            reply_to: nil,
            request_id: nil,
            status: :idle,
            messages: [],
            last_action: nil,
            action_history: [],
            recent_errors: [],
            final_response: nil,
            counters: %{
              iteration: 0,
              max_iterations: 50,
              consecutive_failures: 0,
              max_failures: 3,
              repeat_count: 0,
              syntax_failures: 0,
              goal_tracker_blocks: 0
            },
            provider: %{
              name: nil,
              module: nil,
              escalated: false,
              original: nil,
              last_compile_error: nil
            },
            verification: %{
              pending: false,
              test_status: :untested,
              baseline: :unknown
            },
            goal: %{
              last_impact_map: nil,
              modified_files: MapSet.new()
            },
            pending_tool_calls: [],
            pending_approval: nil,
            transaction: %Transaction{}

  # ============================================================================
  # Constructor / Lifecycle
  # ============================================================================

  @doc """
  Build initial state from keyword opts.
  Accepts both new grouped keys and legacy flat keys for convenience.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base = %__MODULE__{}

    Enum.reduce(opts, base, fn
      {:task, v}, s -> %{s | task: v}
      {:project_path, v}, s -> %{s | project_path: v}
      {:project_pid, v}, s -> %{s | project_pid: v}
      {:reply_to, v}, s -> %{s | reply_to: v}
      {:request_id, v}, s -> %{s | request_id: v}
      {:status, v}, s -> %{s | status: v}
      {:messages, v}, s -> %{s | messages: v}
      {:transaction, v}, s -> %{s | transaction: v}
      {:max_iterations, v}, s -> put_in(s.counters.max_iterations, v)
      {:max_failures, v}, s -> put_in(s.counters.max_failures, v)
      _, s -> s
    end)
  end

  @doc """
  Reset task state while preserving identity (project_path, project_pid).
  Mirrors the old Orchestrator.reset_state/1 logic.
  """
  @spec reset(t()) :: t()
  def reset(state) do
    %{
      state
      | task: nil,
        status: :idle,
        messages: [],
        reply_to: nil,
        last_action: nil,
        action_history: [],
        recent_errors: [],
        final_response: nil,
        counters: %{
          state.counters
          | iteration: 0,
            consecutive_failures: 0,
            repeat_count: 0
        },
        verification: %{
          state.verification
          | pending: false,
            test_status: :untested
        },
        goal: %{
          last_impact_map: nil,
          modified_files: MapSet.new()
        },
        pending_tool_calls: [],
        transaction: Transaction.new()
    }
  end

  # ============================================================================
  # Counter Operations
  # ============================================================================

  @spec increment_iteration(t()) :: t()
  def increment_iteration(state) do
    put_in(state.counters.iteration, state.counters.iteration + 1)
  end

  @spec increment_failures(t()) :: t()
  def increment_failures(state) do
    put_in(state.counters.consecutive_failures, state.counters.consecutive_failures + 1)
  end

  @spec reset_failures(t()) :: t()
  def reset_failures(state) do
    put_in(state.counters.consecutive_failures, 0)
  end

  @spec increment_syntax_failures(t()) :: t()
  def increment_syntax_failures(state) do
    put_in(state.counters.syntax_failures, state.counters.syntax_failures + 1)
  end

  @spec increment_repeat(t()) :: t()
  def increment_repeat(state) do
    put_in(state.counters.repeat_count, state.counters.repeat_count + 1)
  end

  @spec reset_repeat(t()) :: t()
  def reset_repeat(state) do
    put_in(state.counters.repeat_count, 0)
  end

  @spec increment_goal_blocks(t()) :: t()
  def increment_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, state.counters.goal_tracker_blocks + 1)
  end

  @spec reset_goal_blocks(t()) :: t()
  def reset_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, 0)
  end

  @spec set_max_iterations(t(), pos_integer()) :: t()
  def set_max_iterations(state, n) do
    put_in(state.counters.max_iterations, n)
  end

  @spec bump_max_iterations(t(), pos_integer()) :: t()
  def bump_max_iterations(state, bonus) do
    put_in(state.counters.max_iterations, state.counters.max_iterations + bonus)
  end

  @spec set_syntax_failures(t(), non_neg_integer()) :: t()
  def set_syntax_failures(state, n) do
    put_in(state.counters.syntax_failures, n)
  end

  # ============================================================================
  # Counter Predicates
  # ============================================================================

  @spec max_iterations?(t()) :: boolean()
  def max_iterations?(state) do
    state.counters.iteration >= state.counters.max_iterations
  end

  @spec max_failures?(t()) :: boolean()
  def max_failures?(state) do
    state.counters.consecutive_failures >= state.counters.max_failures
  end

  # ============================================================================
  # History Operations
  # ============================================================================

  @spec push_action(t(), {String.t(), map()}) :: t()
  def push_action(state, action) do
    %{state | last_action: action}
  end

  @spec record_action(t(), {String.t(), map(), any()}) :: t()
  def record_action(state, {tool, params, result}) do
    %{
      state
      | last_action: {tool, params},
        action_history: [{tool, params, result} | Enum.take(state.action_history, 4)]
    }
  end

  @spec push_error(t(), any()) :: t()
  def push_error(state, error) do
    %{state | recent_errors: [error | Enum.take(state.recent_errors, 9)]}
  end

  @spec push_message(t(), map()) :: t()
  def push_message(state, message) do
    %{state | messages: state.messages ++ [message]}
  end

  @spec push_messages(t(), list(map())) :: t()
  def push_messages(state, msgs) do
    %{state | messages: state.messages ++ msgs}
  end

  @spec set_messages(t(), list()) :: t()
  def set_messages(state, messages) do
    %{state | messages: messages}
  end

  @spec clear_messages(t()) :: t()
  def clear_messages(state) do
    %{state | messages: []}
  end

  # ============================================================================
  # Repeat Detection
  # ============================================================================

  @spec repeating?(t(), {String.t(), map()}) :: boolean()
  def repeating?(state, action) do
    state.last_action == action
  end

  @spec stuck_in_loop?(t(), non_neg_integer()) :: boolean()
  def stuck_in_loop?(state, threshold \\ 3) do
    state.counters.repeat_count >= threshold
  end

  # ============================================================================
  # Provider Management
  # ============================================================================

  @spec set_provider(t(), atom() | String.t(), module()) :: t()
  def set_provider(state, name, module) do
    %{state | provider: %{state.provider | name: name, module: module}}
  end

  @spec escalate_provider(t(), atom() | String.t(), module()) :: t()
  def escalate_provider(state, name, module) do
    %{
      state
      | provider: %{
          state.provider
          | name: name,
            module: module,
            escalated: true,
            original: state.provider.name
        }
    }
  end

  @spec mark_escalated(t()) :: t()
  def mark_escalated(state) do
    put_in(state.provider.escalated, true)
  end

  @spec set_last_compile_error(t(), String.t() | nil) :: t()
  def set_last_compile_error(state, error) do
    put_in(state.provider.last_compile_error, error)
  end

  # ============================================================================
  # Verification State
  # ============================================================================

  @spec set_pending_verification(t(), boolean()) :: t()
  def set_pending_verification(state, bool) do
    put_in(state.verification.pending, bool)
  end

  @spec set_test_status(t(), :untested | :red | :green) :: t()
  def set_test_status(state, status) do
    put_in(state.verification.test_status, status)
  end

  @spec set_baseline(t(), :clean | :dirty | :unknown) :: t()
  def set_baseline(state, status) do
    put_in(state.verification.baseline, status)
  end

  # ============================================================================
  # Goal Tracker
  # ============================================================================

  @spec set_impact_map(t(), map()) :: t()
  def set_impact_map(state, map) do
    put_in(state.goal.last_impact_map, map)
  end

  @spec track_modified_file(t(), String.t()) :: t()
  def track_modified_file(state, path) do
    put_in(state.goal.modified_files, MapSet.put(state.goal.modified_files, path))
  end

  @spec goal_coverage(t()) :: float()
  def goal_coverage(state) do
    case state.goal.last_impact_map do
      %{count: count} when count > 0 ->
        MapSet.size(state.goal.modified_files) / count

      _ ->
        0.0
    end
  end

  # ============================================================================
  # Tool / Approval / Transaction
  # ============================================================================

  @spec set_pending_approval(t(), map()) :: t()
  def set_pending_approval(state, approval) do
    %{state | pending_approval: approval}
  end

  @spec clear_pending_approval(t()) :: t()
  def clear_pending_approval(state) do
    %{state | pending_approval: nil}
  end

  @spec set_pending_tool_calls(t(), list()) :: t()
  def set_pending_tool_calls(state, calls) do
    %{state | pending_tool_calls: calls}
  end

  @spec set_transaction(t(), Transaction.t()) :: t()
  def set_transaction(state, txn) do
    %{state | transaction: txn}
  end

  # ============================================================================
  # Flat Field Setters
  # ============================================================================

  @spec set_status(t(), atom()) :: t()
  def set_status(state, status) do
    %{state | status: status}
  end

  @spec set_final_response(t(), String.t() | nil) :: t()
  def set_final_response(state, response) do
    %{state | final_response: response}
  end

  @spec set_task(t(), String.t() | nil) :: t()
  def set_task(state, task) do
    %{state | task: task}
  end

  @spec set_request_id(t(), String.t() | nil) :: t()
  def set_request_id(state, id) do
    %{state | request_id: id}
  end

  @spec set_reply_to(t(), any()) :: t()
  def set_reply_to(state, reply_to) do
    %{state | reply_to: reply_to}
  end

  # ============================================================================
  # Accessor Helpers (for Trace and Orchestrator reads)
  # ============================================================================

  @spec iteration(t()) :: non_neg_integer()
  def iteration(state), do: state.counters.iteration

  @spec max_iterations(t()) :: pos_integer()
  def max_iterations(state), do: state.counters.max_iterations

  @spec consecutive_failures(t()) :: non_neg_integer()
  def consecutive_failures(state), do: state.counters.consecutive_failures

  @spec max_failures(t()) :: pos_integer()
  def max_failures(state), do: state.counters.max_failures

  @spec repeat_count(t()) :: non_neg_integer()
  def repeat_count(state), do: state.counters.repeat_count

  @spec syntax_failures(t()) :: non_neg_integer()
  def syntax_failures(state), do: state.counters.syntax_failures

  @spec goal_tracker_blocks(t()) :: non_neg_integer()
  def goal_tracker_blocks(state), do: state.counters.goal_tracker_blocks

  @spec provider_name(t()) :: atom() | String.t() | nil
  def provider_name(state), do: state.provider.name

  @spec provider_module(t()) :: module() | nil
  def provider_module(state), do: state.provider.module

  @spec escalated?(t()) :: boolean()
  def escalated?(state), do: state.provider.escalated

  @spec pending_verification?(t()) :: boolean()
  def pending_verification?(state), do: state.verification.pending

  @spec test_status(t()) :: :untested | :red | :green
  def test_status(state), do: state.verification.test_status

  @spec baseline_status(t()) :: :clean | :dirty | :unknown
  def baseline_status(state), do: state.verification.baseline
end
