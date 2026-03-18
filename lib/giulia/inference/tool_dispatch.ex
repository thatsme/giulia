defmodule Giulia.Inference.ToolDispatch do
  @moduledoc """
  Tool execution facade. Routes tool calls through loop detection, guards,
  approval gating, and dispatches to the correct sub-module.

  Returns directives: {:next, action, state} | {:done, result, state} | {:halt, state}

  Sub-modules (Build 114):
  - `ToolDispatch.Executor`  — normal tool execution lifecycle
  - `ToolDispatch.Staging`   — transaction mode staging
  - `ToolDispatch.Special`   — bulk replace, rename, commit interceptors
  - `ToolDispatch.Approval`  — approval gating + callbacks
  - `ToolDispatch.Guards`    — preflight, loop detection, guard clauses
  """

  alias Giulia.Inference.State
  alias Giulia.Inference.ToolDispatch.{Approval, Executor, Guards, Special, Staging}

  # Subset of write tools that are staged when transaction_mode is active
  @stageable_tools ["write_file", "edit_file", "write_function", "patch_function"]

  @type directive ::
          {:next, atom() | tuple(), State.t()}
          | {:done, term(), State.t()}
          | {:halt, State.t()}

  # Delegated public helpers
  @spec extract_downstream_dependents(String.t()) :: [String.t()]
  defdelegate extract_downstream_dependents(result_str), to: Guards

  @spec module_to_path(String.t()) :: String.t()
  defdelegate module_to_path(module_name), to: Guards

  @spec find_last_successful_observation(map()) :: String.t() | nil
  defdelegate find_last_successful_observation(state), to: Guards

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Execute a tool call. Handles loop detection, preflight, approval gating,
  and dispatches to the correct execution path. Returns a directive.
  """
  @spec execute(String.t(), map(), map(), State.t()) :: directive()
  def execute(tool_name, params, response, state) do
    current_action = {tool_name, params}

    # Loop detection
    {state, looping?} =
      if State.repeating?(state, current_action) do
        state = State.increment_repeat(state)
        {state, State.stuck_in_loop?(state, 2)}
      else
        {State.reset_repeat(state), false}
      end

    if looping? do
      Guards.handle_loop(tool_name, state)
    else
      # GUARD: Block edit_file after a failed patch_function on the same module
      if Guards.edit_file_after_patch_failure?(tool_name, state) do
        Guards.handle_blocked_edit_file(params, response, state)
      else
        # TRANSACTIONAL EXOSKELETON: Auto-enable for hub modules
        state = Guards.maybe_auto_enable_transaction(tool_name, params, state)

        # Pre-flight check
        case Guards.preflight_check(tool_name, params) do
          :ok ->
            # Check if tool requires approval (skip for staged writes)
            if state.transaction.mode and tool_name in @stageable_tools do
              execute_direct(tool_name, params, response, state)
            else
              if Guards.requires_approval?(tool_name, params, state) do
                Approval.execute_with_approval(tool_name, params, response, state)
              else
                execute_direct(tool_name, params, response, state)
              end
            end

          {:error, preflight_error} ->
            Guards.handle_preflight_failure(tool_name, params, preflight_error, response, state)
        end
      end
    end
  end

  # ============================================================================
  # Approval Response (called from Orchestrator)
  # ============================================================================

  @doc """
  Handle an approval response (approved, rejected, or timed out).
  Called from Orchestrator's handle_info when an approval comes in.
  """
  @spec handle_approval_response(atom() | {:timeout, any()}, map(), State.t()) :: directive()
  def handle_approval_response(:approved, pending, state) do
    Approval.handle_approved(pending, state, &execute_direct/4)
  end

  def handle_approval_response(:rejected, pending, state) do
    Approval.handle_rejected(pending, state)
  end

  def handle_approval_response({:timeout, reason}, pending, state) do
    Approval.handle_timed_out(pending, reason, state)
  end

  # ============================================================================
  # Direct Execution (Dispatcher)
  # ============================================================================

  @doc "Execute tool directly (no approval needed or already approved)."
  @spec execute_direct(String.t(), map(), map(), State.t()) :: directive()
  def execute_direct(tool_name, params, response, state) do
    cond do
      # Intercept commit_changes — route back to Engine
      tool_name == "commit_changes" ->
        Special.execute_commit_changes(params, response, state)

      # Stage write tools when transaction mode is on
      state.transaction.mode and tool_name in @stageable_tools ->
        Staging.execute_staged(tool_name, params, response, state)

      # Overlay read_file with staged content when transaction mode is on
      state.transaction.mode and tool_name == "read_file" ->
        Staging.execute_read_with_overlay(params, response, state, &Executor.execute_normal/4)

      # Intercept get_staged_files
      tool_name == "get_staged_files" ->
        Staging.execute_get_staged_files(response, state)

      # Intercept bulk_replace
      tool_name == "bulk_replace" ->
        Special.execute_bulk_replace(params, response, state)

      # Intercept rename_mfa
      tool_name == "rename_mfa" ->
        Special.execute_rename_mfa(params, response, state)

      # Normal execution path
      true ->
        Executor.execute_normal(tool_name, params, response, state)
    end
  end
end
