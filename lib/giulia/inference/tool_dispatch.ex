defmodule Giulia.Inference.ToolDispatch do
  @moduledoc """
  All tool execution paths: from tool name to result recorded in state.

  Returns directives: {:next, action, state} | {:done, result, state} | {:halt, state}
  Extracted from Orchestrator in build 84.
  """

  require Logger

  alias Giulia.Inference.{Approval, BulkReplace, ContextBuilder, Events, RenameMFA, State, Transaction}
  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.Context.Store

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Subset of write tools that are staged when transaction_mode is active
  @stageable_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Read-only tools that never modify code
  @read_only_tools ~w(get_impact_map trace_path get_module_info search_code read_file
                       list_files lookup_function get_function get_context cycle_check)

  @type directive ::
          {:next, atom() | tuple(), State.t()}
          | {:done, term(), State.t()}
          | {:halt, State.t()}

  # ============================================================================
  # Main Entry Points
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
      handle_loop(tool_name, state)
    else
      # GUARD: Block edit_file after a failed patch_function on the same module
      if edit_file_after_patch_failure?(tool_name, state) do
        handle_blocked_edit_file(params, response, state)
      else
        # TRANSACTIONAL EXOSKELETON: Auto-enable for hub modules
        state = maybe_auto_enable_transaction(tool_name, params, state)

        # Pre-flight check
        case preflight_check(tool_name, params) do
          :ok ->
            # Check if tool requires approval (skip for staged writes)
            if state.transaction.mode and tool_name in @stageable_tools do
              execute_direct(tool_name, params, response, state)
            else
              if requires_approval?(tool_name, params, state) do
                execute_with_approval(tool_name, params, response, state)
              else
                execute_direct(tool_name, params, response, state)
              end
            end

          {:error, preflight_error} ->
            Logger.warning("Preflight failed for #{tool_name}: #{preflight_error}")
            handle_preflight_failure(tool_name, params, preflight_error, response, state)
        end
      end
    end
  end

  @doc """
  Handle an approval response (approved, rejected, or timed out).
  Called from Orchestrator's handle_info when an approval comes in.
  """
  @spec handle_approval_response(atom() | {:timeout, any()}, map(), State.t()) :: directive()
  def handle_approval_response(:approved, pending, state) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.info("Approval granted for #{tool_name}")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :approval_granted,
        approval_id: pending.approval_id,
        tool: tool_name
      })
    end

    execute_direct(tool_name, params, response, state)
  end

  def handle_approval_response(:rejected, pending, state) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.info("Approval rejected for #{tool_name}")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :approval_rejected,
        approval_id: pending.approval_id,
        tool: tool_name
      })
    end

    handle_rejection(tool_name, params, response, state)
  end

  def handle_approval_response({:timeout, reason}, pending, state) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.warning("Approval timeout for #{tool_name}: #{inspect(reason)}")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :approval_timeout,
        approval_id: pending.approval_id,
        tool: tool_name
      })
    end

    handle_timeout(tool_name, params, response, state)
  end

  # ============================================================================
  # Direct Execution (Dispatcher)
  # ============================================================================

  @doc "Execute tool directly (no approval needed or already approved)."
  def execute_direct(tool_name, params, response, state) do
    cond do
      # Intercept commit_changes — route back to Engine
      tool_name == "commit_changes" ->
        execute_commit_changes(params, response, state)

      # Stage write tools when transaction mode is on
      state.transaction.mode and tool_name in @stageable_tools ->
        execute_staged(tool_name, params, response, state)

      # Overlay read_file with staged content when transaction mode is on
      state.transaction.mode and tool_name == "read_file" ->
        execute_read_with_overlay(params, response, state)

      # Intercept get_staged_files
      tool_name == "get_staged_files" ->
        execute_get_staged_files(response, state)

      # Intercept bulk_replace
      tool_name == "bulk_replace" ->
        execute_bulk_replace(params, response, state)

      # Intercept rename_mfa
      tool_name == "rename_mfa" ->
        execute_rename_mfa(params, response, state)

      # Normal execution path
      true ->
        execute_normal(tool_name, params, response, state)
    end
  end

  # ============================================================================
  # Normal Execution
  # ============================================================================

  defp execute_normal(tool_name, params, response, state) do
    # BROADCAST: Tool call starting
    if state.request_id do
      Logger.info("OODA BROADCAST: tool_call #{tool_name} to #{state.request_id}")

      Events.broadcast(state.request_id, %{
        type: :tool_call,
        iteration: State.iteration(state),
        tool: tool_name,
        params: ContextBuilder.sanitize_params_for_broadcast(params)
      })
    end

    Logger.info("=== TOOL CALL [#{State.iteration(state)}] ===")
    Logger.info("Tool: #{tool_name}")
    Logger.info("Params: #{inspect(params, pretty: true, limit: 500)}")

    # EXECUTE
    tool_opts = ContextBuilder.build_tool_opts(state)

    result =
      try do
        Registry.execute(tool_name, params, tool_opts)
      rescue
        e in FunctionClauseError ->
          {:error,
           "Invalid parameters for #{tool_name}. Check required fields. Details: #{Exception.message(e)}"}

        e ->
          {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
      end

    # Log result
    result_preview =
      case result do
        {:ok, data} when is_binary(data) -> data
        {:ok, data} -> inspect(data, pretty: true, limit: :infinity)
        {:error, reason} -> "ERROR: #{inspect(reason)}"
        other -> inspect(other, limit: :infinity)
      end

    Logger.info("Result: #{result_preview}")
    Logger.info("=== END TOOL CALL ===")

    # AUTO READ-BACK
    result = maybe_inject_readback(tool_name, params, result, tool_opts)

    # BROADCAST: Tool result
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_result,
        tool: tool_name,
        success: match?({:ok, _}, result),
        preview: result_preview
      })
    end

    # Record in history
    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})
    messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, result})
      |> State.reset_failures()
      |> State.reset_goal_blocks()

    # TEST-LOCK: Track test results
    state =
      if tool_name == "run_tests" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            if String.contains?(result_str, "0 failures") or
                 String.starts_with?(result_str, "ALL TESTS PASSED") do
              Logger.info("TEST-LOCK: Tests are GREEN")
              State.set_test_status(state, :green)
            else
              Logger.info("TEST-LOCK: Tests are RED")
              State.set_test_status(state, :red)
            end

          _ ->
            Logger.info("TEST-LOCK: Tests are RED (error)")
            State.set_test_status(state, :red)
        end
      else
        state
      end

    # GOAL TRACKER: Capture impact_map results
    state =
      if tool_name == "get_impact_map" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            dependents = extract_downstream_dependents(result_str)
            module = params["module"] || params[:module] || "unknown"

            if dependents != [] do
              Logger.info("GOAL TRACKER: Captured #{length(dependents)} dependents for #{module}")

              State.set_impact_map(state, %{
                module: module,
                dependents: dependents,
                count: length(dependents)
              })
            else
              state
            end

          _ ->
            state
        end
      else
        state
      end

    # GOAL TRACKER: Track modified files
    state =
      if tool_name in @write_tools do
        path = params["path"] || params[:path] || params["file"] || params[:file]

        if path do
          resolved = ContextBuilder.resolve_tool_path(path, state)
          State.track_modified_file(state, resolved)
        else
          state
        end
      else
        state
      end

    # VERIFY: Auto-compile after write operations
    if tool_name in @write_tools do
      {:next, {:verify, tool_name, result}, State.set_pending_verification(state, true)}
    else
      # OBSERVE: Feed result back
      observation = Builder.format_observation(tool_name, result)
      messages = state.messages ++ [%{role: "user", content: observation}]
      {:next, :step, State.set_messages(state, messages)}
    end
  end

  # ============================================================================
  # Staged Execution (Transaction Mode)
  # ============================================================================

  defp execute_staged(tool_name, params, response, state) do
    # BROADCAST
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_call,
        iteration: State.iteration(state),
        tool: tool_name,
        params: ContextBuilder.sanitize_params_for_broadcast(params),
        staged: true
      })
    end

    Logger.info("=== STAGED TOOL CALL [#{State.iteration(state)}] ===")
    Logger.info("Tool: #{tool_name} (transaction mode)")

    resolve_fn = &ContextBuilder.resolve_tool_path(&1, state)

    {result, new_tx} =
      case tool_name do
        "write_file" ->
          Transaction.stage_write(state.transaction, params, resolve_fn)

        "edit_file" ->
          Transaction.stage_edit(state.transaction, params, resolve_fn)

        tool when tool in ["patch_function", "write_function"] ->
          Transaction.stage_ast(state.transaction, tool, params,
            project_path: state.project_path,
            resolve_fn: resolve_fn,
            tool_opts: ContextBuilder.build_tool_opts(state)
          )

        _ ->
          {{:error, "Unknown stageable tool: #{tool_name}"}, state.transaction}
      end

    state = State.set_transaction(state, new_tx)

    {result_preview, observation} =
      case result do
        {:ok, msg} ->
          staged_count = map_size(state.transaction.staging_buffer)

          obs =
            "[STAGED] #{tool_name}: #{msg}\nCurrently staging #{staged_count} file(s). Use commit_changes to flush to disk."

          {String.slice(msg, 0, 200), obs}

        {:error, reason} ->
          error_str = if is_binary(reason), do: reason, else: inspect(reason)
          {"ERROR: #{error_str}", "ERROR: #{tool_name} staging failed: #{error_str}"}
      end

    Logger.info("Staged result: #{result_preview}")
    Logger.info("=== END STAGED TOOL CALL ===")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_result,
        tool: tool_name,
        success: match?({:ok, _}, result),
        preview: result_preview,
        staged: true
      })
    end

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, result})
      |> State.reset_failures()
      |> State.reset_goal_blocks()

    {:next, :step, state}
  end

  # ============================================================================
  # Read with Overlay
  # ============================================================================

  defp execute_read_with_overlay(params, response, state) do
    path = params["path"] || params[:path] || params["file"] || params[:file]
    resolved_path = ContextBuilder.resolve_tool_path(path, state)

    case Transaction.read_with_overlay(state.transaction, resolved_path) do
      nil ->
        # Not in staging buffer — normal read
        execute_normal("read_file", params, response, state)

      staged_content ->
        Logger.info("READ OVERLAY: Returning staged content for #{path}")

        result = {:ok, "[STAGED VERSION — not yet on disk]\n#{staged_content}"}

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: State.iteration(state),
            tool: "read_file",
            params: ContextBuilder.sanitize_params_for_broadcast(params),
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "read_file",
            success: true,
            preview: "[STAGED] #{String.slice(staged_content, 0, 100)}",
            staged: true
          })
        end

        assistant_msg =
          response.content || Jason.encode!(%{tool: "read_file", parameters: params})

        observation = Builder.format_observation("read_file", result)

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_messages(messages)
          |> State.record_action({"read_file", params, result})
          |> State.reset_failures()

        {:next, :step, state}
    end
  end

  # ============================================================================
  # Get Staged Files
  # ============================================================================

  defp execute_get_staged_files(response, state) do
    result = {:ok, Transaction.format_staged_files(state.transaction)}

    assistant_msg =
      response.content || Jason.encode!(%{tool: "get_staged_files", parameters: %{}})

    observation = Builder.format_observation("get_staged_files", result)

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({"get_staged_files", %{}, :ok})
      |> State.reset_failures()

    {:next, :step, state}
  end

  # ============================================================================
  # Bulk Replace
  # ============================================================================

  defp execute_bulk_replace(params, response, state) do
    file_list = params["file_list"] || params[:file_list] || []

    state =
      if not state.transaction.mode and file_list != [] do
        Logger.info("BULK_REPLACE: Auto-enabling transaction mode for batch operation")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :transaction_auto_enabled,
            reason: "bulk_replace across #{length(file_list)} files"
          })
        end

        State.set_transaction(state, %{state.transaction | mode: true})
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &ContextBuilder.resolve_tool_path(&1, state),
      modified_files: state.goal.modified_files
    ]

    case BulkReplace.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: State.iteration(state),
            tool: "bulk_replace",
            params: %{pattern: meta.pattern, replacement: meta.replacement,
                       files: meta.file_count},
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "bulk_replace",
            success: meta.total_replacements > 0,
            preview: "#{length(meta.staged)} files staged, #{meta.total_replacements} replacements",
            staged: true
          })
        end

        assistant_msg =
          response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_transaction(new_tx)
          |> put_in([Access.key(:goal), :modified_files], modified_files)
          |> State.set_messages(messages)
          |> State.record_action({"bulk_replace", params, {:ok, "staged"}})
          |> State.reset_failures()

        {:next, :step, state}

      {:error, reason} ->
        send_bulk_error(reason, params, response, state)
    end
  end

  defp send_bulk_error(reason, params, response, state) do
    observation = "ERROR: bulk_replace failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state |> State.set_messages(messages) |> State.increment_failures()
    {:next, :step, state}
  end

  # ============================================================================
  # Rename MFA
  # ============================================================================

  defp execute_rename_mfa(params, response, state) do
    state =
      if not state.transaction.mode do
        module = params["module"] || params[:module]
        old_name = params["old_name"] || params[:old_name]
        arity = params["arity"] || params[:arity]
        new_name = params["new_name"] || params[:new_name]
        Logger.info("RENAME_MFA: Auto-enabling transaction mode")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :transaction_auto_enabled,
            reason: "rename_mfa: #{module}.#{old_name}/#{arity} → #{new_name}"
          })
        end

        State.set_transaction(state, %{state.transaction | mode: true})
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &ContextBuilder.resolve_tool_path(&1, state),
      modified_files: state.goal.modified_files
    ]

    case RenameMFA.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: State.iteration(state),
            tool: "rename_mfa",
            params: %{module: meta.module, old_name: meta.old_name,
                       new_name: meta.new_name, arity: meta.arity},
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "rename_mfa",
            success: meta.total_changes > 0,
            preview: "#{length(meta.staged)} files, #{meta.total_changes} renames",
            staged: true
          })
        end

        assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_transaction(new_tx)
          |> put_in([Access.key(:goal), :modified_files], modified_files)
          |> State.set_messages(messages)
          |> State.record_action({"rename_mfa", params, {:ok, "staged"}})
          |> State.reset_failures()

        {:next, :step, state}

      {:error, reason} ->
        send_rename_error(reason, params, response, state)
    end
  end

  defp send_rename_error(reason, params, response, state) do
    observation = "ERROR: rename_mfa failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state |> State.set_messages(messages) |> State.increment_failures()
    {:next, :step, state}
  end

  # ============================================================================
  # Commit Changes (Route to Engine)
  # ============================================================================

  defp execute_commit_changes(params, response, state) do
    if map_size(state.transaction.staging_buffer) == 0 do
      observation = "Nothing staged to commit. Use write_file or edit_file first."

      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages =
        state.messages ++
          [
            %{role: "assistant", content: assistant_msg},
            %{role: "user", content: observation}
          ]

      state = state |> State.set_messages(messages) |> State.reset_failures()
      {:next, :step, state}
    else
      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]
      state = State.set_messages(state, messages)
      {:next, {:commit_changes, params}, state}
    end
  end

  # ============================================================================
  # Approval Flow
  # ============================================================================

  defp execute_with_approval(tool_name, params, response, state) do
    Logger.info("Tool #{tool_name} requires approval - entering wait state")

    preview = ContextBuilder.generate_preview(tool_name, params, state)
    approval_id = "approval-#{:erlang.phash2(state.request_id)}-#{State.iteration(state)}"

    hub_warning = ContextBuilder.assess_hub_risk(tool_name, params, state.project_path)

    preview =
      if hub_warning do
        "#{hub_warning}\n\n#{preview}"
      else
        preview
      end

    broadcast_payload = %{
      type: :tool_requires_approval,
      approval_id: approval_id,
      iteration: State.iteration(state),
      tool: tool_name,
      params: ContextBuilder.sanitize_params_for_broadcast(params),
      preview: preview
    }

    broadcast_payload =
      if hub_warning do
        Map.put(broadcast_payload, :hub_risk, :high)
      else
        broadcast_payload
      end

    if state.request_id do
      Events.broadcast(state.request_id, broadcast_payload)
    end

    Approval.request_approval_async(
      approval_id,
      tool_name,
      params,
      preview,
      self(),
      timeout: 300_000
    )

    pending = %{
      approval_id: approval_id,
      tool: tool_name,
      params: params,
      response: response
    }

    state = state |> State.set_status(:waiting_for_approval) |> State.set_pending_approval(pending)

    {:halt, state}
  end

  defp handle_rejection(tool_name, params, response, state) do
    rejection_msg = """
    USER REJECTED: Your proposed #{tool_name} was rejected by the user.

    They declined the following change:
    #{ContextBuilder.format_params_brief(params)}

    Please propose a different approach or use 'respond' to ask the user for clarification.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: rejection_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :rejected}})
      |> State.reset_failures()

    {:next, :step, state}
  end

  defp handle_timeout(tool_name, params, response, state) do
    timeout_msg = """
    APPROVAL TIMEOUT: No response received for #{tool_name}.

    The user did not respond to the approval request in time.
    Please use 'respond' to inform the user that approval is needed for this change.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: timeout_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :timeout}})
      |> State.reset_failures()

    {:next, :step, state}
  end

  # ============================================================================
  # Loop Detection
  # ============================================================================

  defp handle_loop(tool_name, state) do
    Logger.warning("Same action repeated #{State.repeat_count(state)}x")

    if tool_name in @read_only_tools do
      Logger.warning(
        "HEURISTIC COMPLETION: Read-only tool loop on #{tool_name}, delivering result directly"
      )

      last_observation = find_last_successful_observation(state)

      if last_observation do
        heuristic_response = """
        #{last_observation}

        ---
        _Task completed via Heuristic Completion. The model retrieved this data but entered a response loop. \
        The Orchestrator is delivering the result directly._
        """

        {:done, {:ok, heuristic_response}, state}
      else
        {:next, :intervene, state}
      end
    else
      Logger.warning("Write-tool loop — intervening with context purge")
      {:next, :intervene, state}
    end
  end

  @doc "Find the best successful tool observation (longest) from action_history."
  def find_last_successful_observation(state) do
    state.action_history
    |> Enum.flat_map(fn
      {_tool, _params, {:ok, data}} when is_binary(data) and data != "" -> [data]
      _ -> []
    end)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  # ============================================================================
  # Guards & Preflight
  # ============================================================================

  defp edit_file_after_patch_failure?("edit_file", %{
         action_history: [{last_tool, _, {:error, _}} | _]
       })
       when last_tool in ["patch_function", "write_function"] do
    true
  end

  defp edit_file_after_patch_failure?(_, _), do: false

  defp handle_blocked_edit_file(params, response, state) do
    _file = params["file"] || params["path"] || "the target file"
    Logger.warning("BLOCKED: edit_file after patch_function failure — forcing read_file reset")

    error_msg = """
    BLOCKED: You cannot use edit_file right after patch_function failed.
    The file has NOT been modified (patch_function is atomic — it aborts on error).

    Your code had a syntax error. To fix it:
    1. Use read_file to see the CURRENT (unchanged) file
    2. Fix the syntax error in your code
    3. Use patch_function again with corrected code

    Do NOT use edit_file — use patch_function for function replacement.
    """

    assistant_msg = response.content || ""

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({"edit_file", params, {:error, :blocked_after_patch}})

    {:next, :step, state}
  end

  defp preflight_check(tool_name, params)
       when tool_name in ["patch_function", "write_function"] do
    code = params["code"] || params[:code]

    if code && String.trim(code) != "" do
      :ok
    else
      {:error, :missing_code}
    end
  end

  defp preflight_check(_tool_name, _params), do: :ok

  defp handle_preflight_failure(tool_name, params, :missing_code, response, state) do
    func_name = params["function_name"] || "func"
    module = params["module"] || "Module"
    arity = params["arity"] || 0

    error_msg = """
    TOOL CALL REJECTED: #{tool_name} requires code but you didn't provide any.

    You sent <action> but NO CODE after </action>. This will always fail.
    You MUST place the new function code in a ```elixir fenced block after </action>.

    CORRECT FORMAT:
    <action>
    {"tool": "#{tool_name}", "parameters": {"module": "#{module}", "function_name": "#{func_name}", "arity": #{arity}}}
    </action>

    ```elixir
    def #{func_name}(...) do
      # your new code here
    end
    ```

    The code goes in a ```elixir block after </action>, NOT inside JSON.
    Do NOT add any text after the closing ```. Try again.
    """

    assistant_msg = response.content || ""

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :missing_code}})
      |> State.increment_failures()

    {:next, :step, state}
  end

  defp requires_approval?("run_mix", params, _state) do
    command = params["command"] || params[:command] || ""
    command not in ["compile", "help"]
  end

  defp requires_approval?("run_tests", _params, _state), do: false

  defp requires_approval?(tool_name, _params, _state) do
    tool_name in @write_tools
  end

  # ============================================================================
  # Auto-Enable Transaction for Hub Modules
  # ============================================================================

  defp maybe_auto_enable_transaction(tool_name, params, state)
       when tool_name in @stageable_tools do
    {new_tx, new_max} =
      Transaction.maybe_auto_enable(state.transaction, params,
        tool_name: tool_name,
        project_path: state.project_path,
        resolve_module_fn: &ContextBuilder.resolve_module_from_params/3,
        request_id: state.request_id
      )

    state = State.set_transaction(state, new_tx)

    if new_max do
      State.set_max_iterations(state, max(State.max_iterations(state), new_max))
    else
      state
    end
  end

  defp maybe_auto_enable_transaction(_tool_name, _params, state), do: state

  # ============================================================================
  # Auto Read-Back on Tool Failure
  # ============================================================================

  defp maybe_inject_readback(tool_name, params, {:error, reason} = original_error, tool_opts)
       when tool_name in ["edit_file", "write_function", "patch_function"] do
    project_path = Keyword.get(tool_opts, :project_path)
    file_path = get_file_path_from_params(tool_name, params, project_path)

    if file_path do
      case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
        {:ok, file_content} ->
          truncated =
            if String.length(file_content) > 2000 do
              String.slice(file_content, 0, 2000) <>
                "\n\n... [truncated, #{String.length(file_content)} bytes total]"
            else
              file_content
            end

          enhanced_error = """
          #{reason}

          === AUTO READ-BACK: Current file content ===
          #{truncated}
          === END READ-BACK ===

          Use this content to construct a correct edit_file call.
          """

          Logger.info("Auto Read-Back injected for #{file_path}")
          {:error, enhanced_error}

        {:error, read_error} ->
          Logger.warning("Auto Read-Back failed: #{inspect(read_error)}")
          original_error
      end
    else
      original_error
    end
  end

  defp maybe_inject_readback(_tool_name, _params, result, _tool_opts), do: result

  defp get_file_path_from_params("edit_file", params, _project_path) do
    params["file"] || params[:file]
  end

  defp get_file_path_from_params("write_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params("patch_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params(_tool, _params, _project_path), do: nil

  defp lookup_module_file(nil, _project_path), do: nil

  defp lookup_module_file(module_name, project_path) do
    case Store.find_module(project_path, module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end

  # ============================================================================
  # Goal Tracker Helpers
  # ============================================================================

  @doc "Extract downstream dependent module names from impact map output text."
  def extract_downstream_dependents(result_str) do
    case String.split(result_str, "DOWNSTREAM (what depends on me):") do
      [_, downstream_section] ->
        # Stop at FUNCTIONS section before parsing lines
        downstream_only =
          case String.split(downstream_section, ~r/\nFUNCTIONS[:\s]/i, parts: 2) do
            [before, _] -> before
            [all] -> all
          end

        downstream_only
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("- ")
          |> String.split(" (")
          |> List.first()
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == "" or &1 == "(none — nothing depends on this)"))

      _ ->
        []
    end
  end

  @doc "Convert a module name to a path fragment for fuzzy matching."
  def module_to_path(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
