defmodule Giulia.Inference.State do
  @moduledoc """
  Pure-functional state management for the Orchestrator.

  Provides:
  - `@type t` with grouped sub-types (counters, provider, verification, goal)
  - Struct lifecycle (`new/1`, `reset/1`)
  - History, approval, transaction, and flat field setters (local impl)
  - Counter operations (delegated to `State.Counters`)
  - Provider/verification/goal tracking (delegated to `State.Tracking`)

  Extracted from Orchestrator (build 83). Split into facade + sub-modules (Build 110).
  """

  alias Giulia.Inference.Transaction
  alias Giulia.Inference.State.Counters
  alias Giulia.Inference.State.Tracking

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

  @enforce_keys []
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
  # Delegated: Counter Operations (State.Counters)
  # ============================================================================

  @spec increment_iteration(t()) :: t()
  defdelegate increment_iteration(state), to: Counters

  @spec increment_failures(t()) :: t()
  defdelegate increment_failures(state), to: Counters

  @spec reset_failures(t()) :: t()
  defdelegate reset_failures(state), to: Counters

  @spec increment_syntax_failures(t()) :: t()
  defdelegate increment_syntax_failures(state), to: Counters

  @spec set_syntax_failures(t(), non_neg_integer()) :: t()
  defdelegate set_syntax_failures(state, n), to: Counters

  @spec increment_repeat(t()) :: t()
  defdelegate increment_repeat(state), to: Counters

  @spec reset_repeat(t()) :: t()
  defdelegate reset_repeat(state), to: Counters

  @spec increment_goal_blocks(t()) :: t()
  defdelegate increment_goal_blocks(state), to: Counters

  @spec reset_goal_blocks(t()) :: t()
  defdelegate reset_goal_blocks(state), to: Counters

  @spec set_max_iterations(t(), pos_integer()) :: t()
  defdelegate set_max_iterations(state, n), to: Counters

  @spec bump_max_iterations(t(), pos_integer()) :: t()
  defdelegate bump_max_iterations(state, bonus), to: Counters

  @spec max_iterations?(t()) :: boolean()
  defdelegate max_iterations?(state), to: Counters

  @spec max_failures?(t()) :: boolean()
  defdelegate max_failures?(state), to: Counters

  @spec iteration(t()) :: non_neg_integer()
  defdelegate iteration(state), to: Counters

  @spec max_iterations(t()) :: pos_integer()
  defdelegate max_iterations(state), to: Counters

  @spec consecutive_failures(t()) :: non_neg_integer()
  defdelegate consecutive_failures(state), to: Counters

  @spec max_failures(t()) :: pos_integer()
  defdelegate max_failures(state), to: Counters

  @spec repeat_count(t()) :: non_neg_integer()
  defdelegate repeat_count(state), to: Counters

  @spec syntax_failures(t()) :: non_neg_integer()
  defdelegate syntax_failures(state), to: Counters

  @spec goal_tracker_blocks(t()) :: non_neg_integer()
  defdelegate goal_tracker_blocks(state), to: Counters

  # ============================================================================
  # Delegated: Tracking (State.Tracking)
  # ============================================================================

  @spec set_provider(t(), atom() | String.t(), module()) :: t()
  defdelegate set_provider(state, name, module), to: Tracking

  @spec escalate_provider(t(), atom() | String.t(), module()) :: t()
  defdelegate escalate_provider(state, name, module), to: Tracking

  @spec mark_escalated(t()) :: t()
  defdelegate mark_escalated(state), to: Tracking

  @spec set_last_compile_error(t(), String.t() | nil) :: t()
  defdelegate set_last_compile_error(state, error), to: Tracking

  @spec provider_name(t()) :: atom() | String.t() | nil
  defdelegate provider_name(state), to: Tracking

  @spec provider_module(t()) :: module() | nil
  defdelegate provider_module(state), to: Tracking

  @spec escalated?(t()) :: boolean()
  defdelegate escalated?(state), to: Tracking

  @spec set_pending_verification(t(), boolean()) :: t()
  defdelegate set_pending_verification(state, bool), to: Tracking

  @spec set_test_status(t(), :untested | :red | :green) :: t()
  defdelegate set_test_status(state, status), to: Tracking

  @spec set_baseline(t(), :clean | :dirty | :unknown) :: t()
  defdelegate set_baseline(state, status), to: Tracking

  @spec pending_verification?(t()) :: boolean()
  defdelegate pending_verification?(state), to: Tracking

  @spec test_status(t()) :: :untested | :red | :green
  defdelegate test_status(state), to: Tracking

  @spec baseline_status(t()) :: :clean | :dirty | :unknown
  defdelegate baseline_status(state), to: Tracking

  @spec set_impact_map(t(), map()) :: t()
  defdelegate set_impact_map(state, map), to: Tracking

  @spec track_modified_file(t(), String.t()) :: t()
  defdelegate track_modified_file(state, path), to: Tracking

  @spec goal_coverage(t()) :: float()
  defdelegate goal_coverage(state), to: Tracking

  @spec repeating?(t(), {String.t(), map()}) :: boolean()
  defdelegate repeating?(state, action), to: Tracking

  @spec stuck_in_loop?(t(), non_neg_integer()) :: boolean()
  def stuck_in_loop?(state, threshold \\ 3), do: Tracking.stuck_in_loop?(state, threshold)
end
