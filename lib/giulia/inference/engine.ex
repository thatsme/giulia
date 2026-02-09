defmodule Giulia.Inference.Engine do
  @moduledoc """
  OODA loop core — the "brain" of the inference pipeline.

  Receives actions from the Orchestrator's handle_continue, performs them
  (including side effects like provider calls), and returns directives.

  Directive types:
    {:next, action, state}  — continue to next OODA step
    {:done, result, state}  — task complete, reply to caller
    {:halt, state}          — wait (paused, waiting for approval)

  Extracted from Orchestrator in build 84.
  """

  require Logger

  alias Giulia.Provider.Router
  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.StructuredOutput
  alias Giulia.StructuredOutput.Parser
  alias Giulia.Context.Store
  alias Giulia.Core.ProjectContext
  alias Giulia.Inference.{
    ContextBuilder, Escalation, Events, ResponseParser, State, ToolDispatch,
    Transaction, Verification
  }

  @type directive ::
          {:next, atom() | tuple(), State.t()}
          | {:done, term(), State.t()}
          | {:halt, State.t()}

  # ============================================================================
  # Single Entry Point
  # ============================================================================

  @doc """
  Dispatch an action and return a directive.
  This is the ONLY function the Orchestrator's handle_continue calls.
  """
  @spec dispatch(atom() | tuple(), State.t()) :: directive()

  # ---------- START ----------
  def dispatch({:start, prompt, _opts}, state) do
    Logger.info("Orchestrator starting: #{String.slice(prompt, 0, 50)}...")

    Builder.clear_model_tier_cache()

    baseline_status = check_baseline(state)
    state = State.set_baseline(state, baseline_status)

    if baseline_status == :dirty and state.request_id do
      Events.broadcast(state.request_id, %{
        type: :baseline_warning,
        message: "Project has pre-existing compilation errors. Will attempt to work around them."
      })
    end

    # Route to provider
    context_meta = %{file_count: Store.stats(state.project_path).ast_files}
    classification = Router.route(prompt, context_meta)
    Logger.debug("Routed to: #{classification.provider}")

    # Handle native commands (no LLM)
    if classification.provider == :elixir_native do
      result = handle_native_command(prompt, state)
      {:done, result, state}
    else
      case resolve_provider(classification) do
        {:ok, final_provider, final_module} ->
          model_tier = Builder.detect_model_tier()
          detected_name = Application.get_env(:giulia, :detected_model_name, "unknown")

          if state.request_id do
            Events.broadcast(state.request_id, %{
              type: :model_detected,
              model: detected_name,
              tier: model_tier,
              message: "Model: #{detected_name} (#{model_tier} tier)"
            })
          end

          messages = ContextBuilder.build_initial_messages(prompt, state, final_module)

          messages =
            if baseline_status == :dirty do
              baseline_msg = %{
                role: "system",
                content: """
                WARNING: This project has pre-existing compilation errors.
                These errors existed BEFORE you started working.
                Focus on the user's request. Don't try to fix unrelated existing errors unless asked.
                """
              }

              [Enum.at(messages, 0), baseline_msg | Enum.drop(messages, 1)]
            else
              messages
            end

          state = state
            |> State.set_status(:thinking)
            |> State.set_messages(messages)
            |> State.set_provider(final_provider, final_module)
            |> State.reset_failures()
            |> put_in([Access.key(:counters), :iteration], 0)
            |> Map.put(:action_history, [])

          {:next, :step, state}

        :no_provider ->
          {:done, {:error, :no_provider_available}, state}
      end
    end
  end

  # ---------- STEP (paused/waiting guards) ----------
  def dispatch(:step, %{status: :paused} = state), do: {:halt, state}
  def dispatch(:step, %{status: :waiting_for_approval} = state), do: {:halt, state}

  # ---------- STEP (max iterations) ----------
  def dispatch(:step, %{counters: %{iteration: iter, max_iterations: max}} = state)
      when iter >= max do
    Logger.warning("Max iterations reached (#{max})")
    {:done, {:error, :max_iterations_exceeded}, state}
  end

  # ---------- STEP (max failures -> intervene) ----------
  def dispatch(:step, %{counters: %{consecutive_failures: f, max_failures: max}} = state)
      when f >= max do
    Logger.warning("Max consecutive failures (#{max}), intervening...")
    {:next, :intervene, state}
  end

  # ---------- STEP (batched tool call queue) ----------
  def dispatch(:step, %{pending_tool_calls: [next | rest]} = state) do
    state = state |> State.increment_iteration() |> State.set_pending_tool_calls(rest) |> State.set_status(:thinking)
    tool_name = next["tool"]
    params = next["parameters"] || %{}
    Logger.info("Multi-action queue: executing #{tool_name} (#{length(rest)} remaining)")

    synthetic_content = Jason.encode!(%{tool: tool_name, parameters: params})
    synthetic_response = %{content: synthetic_content, tool_calls: nil}

    ToolDispatch.execute(tool_name, params, synthetic_response, state)
  end

  # ---------- STEP (normal) ----------
  def dispatch(:step, state) do
    state = state |> State.increment_iteration() |> State.set_status(:thinking)
    Logger.debug("OODA Loop iteration #{State.iteration(state)}")

    messages = ContextBuilder.inject_distilled_context(state.messages, state)

    case call_provider(State.set_messages(state, messages)) do
      {:ok, response} ->
        handle_model_response(response, state)

      {:error, reason} ->
        Logger.error("Provider error: #{inspect(reason)}")
        state = state |> State.increment_failures() |> State.push_error(reason)
        {:next, :step, state}
    end
  end

  # ---------- INTERVENE ----------
  def dispatch(:intervene, state) do
    Logger.warning("Intervention triggered - CONTEXT PURGE")

    intervention_msg =
      case state.last_action do
        {"run_tests", test_params} ->
          ContextBuilder.build_test_failure_intervention(test_params, state)

        _ ->
          target_file = ContextBuilder.extract_target_file(state)
          fresh_content = if target_file, do: ContextBuilder.read_fresh_content(target_file, state), else: nil
          ContextBuilder.build_intervention_message(state, target_file, fresh_content)
      end

    model_tier = Builder.detect_model_tier()

    prompt_opts = [
      transaction_mode: state.transaction.mode,
      staged_files: Map.keys(state.transaction.staging_buffer)
    ]

    system_prompt = Builder.build_tiered_prompt(model_tier, prompt_opts)

    tool_switch_hint =
      case state.last_action do
        {"patch_function", _} ->
          """

          IMPORTANT: patch_function has failed repeatedly. For RENAMING function calls,
          use edit_file instead: {"tool": "edit_file", "parameters": {"file": "path", "old_text": "old", "new_text": "new"}}
          Do NOT use patch_function for renaming. Use edit_file.
          """

        _ ->
          ""
      end

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: state.task},
      %{role: "assistant", content: "I need to try a different approach."},
      %{role: "user", content: intervention_msg <> tool_switch_hint}
    ]

    state = state
      |> State.set_messages(messages)
      |> State.reset_failures()
      |> State.set_status(:thinking)
      |> Map.put(:action_history, [])
      |> Map.put(:recent_errors, [])

    {:next, :step, state}
  end

  # ---------- ESCALATE ----------
  def dispatch({:escalate, _tool_name, errors}, state) do
    Logger.warning("=== HYBRID ESCALATION v2: Calling Senior Architect ===")

    target_file = ContextBuilder.extract_target_file(state)
    file_content = if target_file, do: ContextBuilder.read_fresh_content(target_file, state), else: nil

    senior_prompt = Escalation.build_prompt(target_file, file_content, errors)

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :escalation_started,
        message: "Senior Architect analyzing error (v2 hybrid)..."
      })
    end

    case Escalation.call(senior_prompt) do
      {:ok, provider_name, response_text} ->
        Logger.info("=== SENIOR ARCHITECT RESPONSE (#{provider_name}) ===")
        Logger.info(String.slice(response_text, 0, 500))

        case Parser.parse_response(response_text) do
          {:ok, %{"tool" => tool_name, "parameters" => params}} ->
            Logger.info("Senior Architect: Executing #{tool_name} directly")

            tool_opts = ContextBuilder.build_tool_opts(state)

            result =
              try do
                Registry.execute(tool_name, params, tool_opts)
              rescue
                e -> {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
              end

            case result do
              {:ok, success_msg} ->
                Logger.info("SENIOR ARCHITECT FIX APPLIED: #{success_msg}")

                if state.request_id do
                  Events.broadcast(state.request_id, %{
                    type: :escalation_complete,
                    provider: provider_name,
                    message: "#{provider_name} applied #{tool_name}: #{success_msg}"
                  })
                end

                observation =
                  "Observation: Senior Architect fixed the build error using #{tool_name}. Build is now green."

                messages = state.messages ++ [%{role: "user", content: observation}]

                state = state
                  |> State.set_messages(messages)
                  |> State.mark_escalated()
                  |> State.set_syntax_failures(0)
                  |> State.set_status(:thinking)

                {:next, {:verify, tool_name, result}, state}

              {:error, tool_error} ->
                Logger.error("Senior Architect tool execution failed: #{inspect(tool_error)}")

                broadcast_escalation_failed(
                  state,
                  "Tool #{tool_name} failed: #{inspect(tool_error)}"
                )

                try_legacy_line_fix(response_text, target_file, provider_name, errors, state)
            end

          {:error, parse_reason} ->
            Logger.info(
              "Hybrid parse failed (#{inspect(parse_reason)}), trying legacy LINE:N/CODE: format"
            )

            try_legacy_line_fix(response_text, target_file, provider_name, errors, state)
        end

      {:error, reason} ->
        Logger.error("Senior Architect escalation failed: #{inspect(reason)}")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :escalation_failed,
            message: "Could not reach Senior Architect: #{inspect(reason)}"
          })
        end

        error_msg = """
        ESCALATION FAILED - Continuing with local model.

        Could not reach Senior Architect. Attempting local fix.

        COMPILER ERROR:
        #{String.slice(errors, 0, 1500)}

        INSTRUCTIONS: Use edit_file to fix the syntax error.
        """

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = state |> State.set_messages(messages) |> State.mark_escalated() |> State.set_status(:thinking)

        {:next, :step, state}
    end
  end

  # ---------- VERIFY ----------
  def dispatch({:verify, tool_name, result}, state) do
    Logger.info("Auto-verifying after #{tool_name}")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :verification_started,
        tool: tool_name,
        message: "Running mix compile..."
      })
    end

    tool_opts = ContextBuilder.build_tool_opts(state)

    case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
      {:ok, output} ->
        case Verification.parse_compile_result(output) do
          :success ->
            Logger.info("Verification passed")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_passed,
                tool: tool_name,
                message: "Build successful"
              })
            end

            state = State.set_pending_verification(state, false)
            {:next, {:auto_regress, tool_name, result, nil}, state}

          {:warnings, warnings} ->
            Logger.info("Verification passed with warnings")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_passed,
                tool: tool_name,
                message: "Build successful (with warnings)",
                warnings: String.slice(warnings, 0, 200)
              })
            end

            state = State.set_pending_verification(state, false)
            {:next, {:auto_regress, tool_name, result, warnings}, state}

          {:error, errors} ->
            Logger.warning("Verification failed - compilation error")
            if state.project_pid, do: ProjectContext.mark_verification_failed(state.project_pid)

            state = State.increment_syntax_failures(state)
            new_syntax_failures = State.syntax_failures(state)
            Logger.info("Syntax failure count: #{new_syntax_failures}")

            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_failed,
                tool: tool_name,
                message: "BUILD BROKEN - Model must fix (attempt #{new_syntax_failures})",
                errors: String.slice(errors, 0, 500)
              })
            end

            total_failures = new_syntax_failures + State.consecutive_failures(state)

            if (new_syntax_failures >= 2 or total_failures >= 2) and not State.escalated?(state) do
              Logger.warning(
                "HYBRID ESCALATION: Local model failed #{new_syntax_failures} times, calling Sonnet"
              )

              if state.request_id do
                Events.broadcast(state.request_id, %{
                  type: :escalation_triggered,
                  message: "Calling Senior Architect for assistance..."
                })
              end

              state = state
                |> State.set_last_compile_error(errors)
                |> State.set_pending_verification(false)

              {:next, {:escalate, tool_name, errors}, state}
            else
              error_msg = """
              ⚠️ SELF-HEALING MODE ACTIVATED ⚠️

              Your #{tool_name} broke the build. You MUST fix this NOW.

              COMPILER ERROR:
              #{String.slice(errors, 0, 1500)}

              INSTRUCTIONS:
              1. DO NOT use lookup_function, get_module_info, or search_code - you already know the file
              2. Use edit_file to fix the specific syntax error shown above
              3. Focus on the exact line mentioned in the error
              4. Make the minimal change needed to fix the syntax

              The file is: #{state.last_action |> elem(1) |> Map.get("file", Map.get(elem(state.last_action, 1), "module", "unknown"))}
              """

              messages = state.messages ++ [%{role: "user", content: error_msg}]

              state = state
                |> State.set_messages(messages)
                |> State.set_pending_verification(false)
                |> State.bump_max_iterations(5)
                |> State.set_last_compile_error(errors)

              Logger.info("Self-healing activated: max_iterations increased to #{State.max_iterations(state)}")
              {:next, :step, state}
            end
        end

      {:error, reason} ->
        Logger.warning("Verification skipped: #{inspect(reason)}")
        observation = Builder.format_observation(tool_name, result)
        messages = state.messages ++ [%{role: "user", content: observation}]
        state = state |> State.set_messages(messages) |> State.set_pending_verification(false)
        {:next, :step, state}
    end
  end

  # ---------- AUTO-REGRESS ----------
  def dispatch({:auto_regress, tool_name, result, warnings}, state) do
    module_name =
      case state.last_action do
        {t, params} when t in ["patch_function", "write_function"] ->
          params["module"] || params[:module]

        {t, params} when t in ["edit_file", "write_file"] ->
          path = params["file"] || params["path"] || params[:file] || params[:path]

          case Store.find_module_by_file(state.project_path, path || "") do
            {:ok, %{name: name}} -> name
            _ -> nil
          end

        _ ->
          nil
      end

    project_path = state.project_path || File.cwd!()

    test_targets =
      if module_name do
        case Giulia.Knowledge.Store.get_test_targets(project_path, module_name) do
          {:ok, %{all_paths: paths}} when paths != [] -> paths
          _ -> []
        end
      else
        []
      end

    if test_targets != [] do
      Logger.info(
        "AUTO-REGRESSION: Running #{length(test_targets)} targeted test file(s) for #{module_name}"
      )

      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :auto_regression_started,
          module: module_name,
          test_files: test_targets
        })
      end

      tool_opts = ContextBuilder.build_tool_opts(state)

      test_results =
        Enum.map(test_targets, fn test_path ->
          case Giulia.Tools.RunTests.execute(%{"file" => test_path}, tool_opts) do
            {:ok, output} -> {test_path, :ok, output}
            {:error, reason} -> {test_path, :error, inspect(reason)}
          end
        end)

      failures =
        Enum.filter(test_results, fn
          {_path, :ok, output} ->
            not (String.contains?(output, "0 failures") or
                   String.starts_with?(output, "ALL TESTS PASSED"))

          {_path, :error, _} ->
            true
        end)

      if failures == [] do
        Logger.info("AUTO-REGRESSION: All #{length(test_targets)} test files passed")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :auto_regression_passed,
            module: module_name,
            test_count: length(test_targets)
          })
        end

        test_summary =
          Enum.map_join(test_results, "\n", fn {path, _, output} ->
            "  ✅ #{path}: #{String.slice(output, 0, 80)}"
          end)

        build_green_observation(tool_name, result, warnings, state, test_summary)
      else
        Logger.warning("AUTO-REGRESSION: #{length(failures)} test file(s) failed")
        state = State.set_test_status(state, :red)

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :auto_regression_failed,
            module: module_name,
            failed_count: length(failures)
          })
        end

        failure_details =
          Enum.map_join(failures, "\n\n", fn {path, _, output} ->
            "❌ #{path}:\n#{String.slice(output, 0, 800)}"
          end)

        regression_msg = """
        #{Builder.format_observation(tool_name, result)}

        ✅ BUILD GREEN — but ❌ DOWNSTREAM REGRESSION DETECTED.

        Giulia automatically verified #{length(test_targets)} test file(s) for #{module_name} and its dependents.
        #{length(failures)} file(s) have failing tests:

        #{failure_details}

        You modified a module that other code depends on. Your change broke downstream logic.
        You MUST fix the regression. Use read_file to examine the failing test, then edit_file or patch_function to fix.
        Do NOT use respond until ALL tests pass.
        """

        messages = state.messages ++ [%{role: "user", content: regression_msg}]
        state = state |> State.set_messages(messages) |> State.bump_max_iterations(5)
        {:next, :step, state}
      end
    else
      Logger.debug("AUTO-REGRESSION: No test targets found for #{module_name || "unknown"}")
      build_green_observation(tool_name, result, warnings, state, nil)
    end
  end

  # ---------- COMMIT CHANGES ----------
  def dispatch({:commit_changes, params}, state) do
    tx = state.transaction
    staged_files = Map.keys(tx.staging_buffer)
    file_count = length(staged_files)
    message = params["message"] || "Committing #{file_count} staged file(s)"

    Logger.info("COMMIT: #{message}")
    Logger.info("COMMIT: Flushing #{file_count} file(s) to disk")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :commit_started,
        file_count: file_count,
        files: staged_files,
        message: message
      })
    end

    # Phase 1: Ensure backups are current
    tx =
      Enum.reduce(staged_files, tx, fn path, acc ->
        Transaction.backup_original(acc, path)
      end)

    state = State.set_transaction(state, tx)

    # Phase 2: Flush all staged files to disk
    write_results =
      Enum.map(tx.staging_buffer, fn {path, content} ->
        {path, File.write(path, content)}
      end)

    write_failures = Enum.filter(write_results, fn {_path, result} -> result != :ok end)

    if write_failures != [] do
      Logger.warning("COMMIT: Write phase failed, rolling back")
      state = State.set_transaction(state, Transaction.rollback(state.transaction, state.project_path))

      error_msg = "COMMIT FAILED (write phase): #{inspect(write_failures)}"

      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :commit_rollback,
          reason: "write_failure",
          files: staged_files,
          message: error_msg
        })
      end

      messages = state.messages ++ [%{role: "user", content: error_msg}]
      state = State.set_messages(state, messages)
      {:next, :step, state}
    else
      # Phase 3: Compile
      Logger.info("COMMIT: Compile phase")
      tool_opts = ContextBuilder.build_tool_opts(state)

      if state.request_id do
        Events.broadcast(state.request_id, %{type: :commit_compiling})
      end

      case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
        {:ok, output} ->
          case Verification.parse_compile_result(output) do
            :success ->
              Logger.info("COMMIT: Compile passed, running integrity check")

              if state.request_id do
                Events.broadcast(state.request_id, %{type: :commit_compile_passed})
              end

              commit_integrity_check(staged_files, params, state)

            {:warnings, _warnings} ->
              Logger.info("COMMIT: Compile passed with warnings, running integrity check")

              if state.request_id do
                Events.broadcast(state.request_id, %{type: :commit_compile_passed, warnings: true})
              end

              commit_integrity_check(staged_files, params, state)

            {:error, errors} ->
              Logger.warning("COMMIT: Compile failed, rolling back")
              state = State.set_transaction(state, Transaction.rollback(state.transaction, state.project_path))

              error_msg = """
              COMMIT FAILED: Compilation errors after flushing staged changes. All changes have been ROLLED BACK.
              All #{length(staged_files)} files are back to their ORIGINAL state. Your staging buffer is cleared.

              COMPILER ERRORS:
              #{String.slice(errors, 0, 1500)}

              POST-ROLLBACK REALITY CHECK:
              Your previous plan was INCONSISTENT. The most common cause is renaming function DEFINITIONS
              without also renaming CALL SITES (or vice versa). In your next transaction, you MUST:
              1. Rename DEFINITIONS (def old_name → def new_name) in all tool/module files
              2. Rename CALL SITES (Module.old_name → Module.new_name) in all callers
              3. Rename any @callback declarations if applicable
              4. Stage ALL of these changes BEFORE calling commit_changes
              Use bulk_replace multiple times — once per pattern — before committing.
              """

              if state.request_id do
                Events.broadcast(state.request_id, %{
                  type: :commit_rollback,
                  reason: "compile_failure",
                  message: "Compilation failed — all changes rolled back",
                  files: staged_files,
                  errors: String.slice(errors, 0, 500)
                })
              end

              messages = state.messages ++ [%{role: "user", content: error_msg}]
              state = State.set_messages(state, messages)
              {:next, :step, state}
          end

        {:error, reason} ->
          Logger.warning("COMMIT: Could not run compile: #{inspect(reason)}, rolling back")
          state = State.set_transaction(state, Transaction.rollback(state.transaction, state.project_path))

          error_msg =
            "COMMIT FAILED: Could not verify compilation: #{inspect(reason)}. Changes rolled back. Staging buffer cleared."

          messages = state.messages ++ [%{role: "user", content: error_msg}]
          state = State.set_messages(state, messages)
          {:next, :step, state}
      end
    end
  end

  # ============================================================================
  # Model Response Handling
  # ============================================================================

  defp handle_model_response(response, state) do
    case ResponseParser.parse(response) do
      {:tool_call, "respond", %{"message" => message}} ->
        handle_respond(message, state)

      {:tool_call, "think", %{"thought" => thought}} ->
        handle_think(thought, response, state)

      {:multi_tool_call, tool_name, params, remaining} ->
        Logger.info("Multi-action: executing #{tool_name}, queuing #{length(remaining)} more")
        state = State.set_pending_tool_calls(state, remaining)
        ToolDispatch.execute(tool_name, params, response, state)

      {:tool_call, tool_name, params} ->
        ToolDispatch.execute(tool_name, params, response, state)

      {:text, text} ->
        handle_plain_text_response(text, response, state)

      {:error, {:json_escape_error, position, malformed_json}} ->
        handle_json_escape_error(position, malformed_json, state)

      {:error, reason} ->
        Logger.warning("Failed to parse response: #{inspect(reason)}")
        state = State.increment_failures(state)
        {:next, :step, state}
    end
  end

  # ============================================================================
  # Response Sub-handlers
  # ============================================================================

  defp handle_respond(message, state) do
    cond do
      # STAGING-LOCK GATE
      state.transaction.mode and map_size(state.transaction.staging_buffer) > 0 ->
        tx = state.transaction
        lock_count = tx.lock_count + 1

        Logger.warning(
          "STAGING-LOCK: Model tried to respond with #{map_size(tx.staging_buffer)} uncommitted staged file(s) (attempt #{lock_count})"
        )

        if lock_count >= 3 do
          Logger.warning(
            "STAGING-LOCK: #{lock_count} consecutive blocks — clearing staging buffer to break deadlock"
          )

          Logger.info("=== TASK COMPLETE (staging-lock release) ===")
          state = State.set_transaction(state, Transaction.new())
          {:done, {:ok, message}, state}
        else
          staged_list =
            tx.staging_buffer |> Map.keys() |> Enum.map_join("\n", &"  - #{&1}")

          lock_msg = """
          BLOCKED: You have uncommitted staged changes in #{map_size(tx.staging_buffer)} file(s):
          #{staged_list}

          You MUST call commit_changes before respond. Or fix your changes and try again.
          """

          messages = state.messages ++ [%{role: "user", content: lock_msg}]
          state = state |> State.set_messages(messages) |> State.set_transaction(%{tx | lock_count: lock_count})
          {:next, :step, state}
        end

      # TEST-LOCK GATE
      State.test_status(state) == :red ->
        Logger.warning("TEST-LOCK: Model tried to respond but tests are still RED")

        lock_msg = """
        BLOCKED: You cannot close this task. Tests are still FAILING.
        You MUST call run_tests and get 0 failures before you can respond.
        Do NOT claim success based on a green build alone.
        DEFINITION OF DONE: build green AND tests green AND verified.
        """

        messages = state.messages ++ [%{role: "user", content: lock_msg}]
        state = State.set_messages(state, messages)
        {:next, :step, state}

      # GOAL TRACKER GATE
      not is_nil(state.goal.last_impact_map) and goal_tracker_blocks?(state) ->
        im = state.goal.last_impact_map
        touched = MapSet.size(state.goal.modified_files)
        state = State.increment_goal_blocks(state)
        block_count = State.goal_tracker_blocks(state)

        Logger.warning(
          "GOAL TRACKER: Model tried to respond after touching #{touched}/#{im.count} dependents of #{im.module} (block #{block_count})"
        )

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :goal_tracker_block,
            module: im.module,
            dependents: im.count,
            modified: touched
          })
        end

        if block_count >= 4 do
          Logger.warning(
            "GOAL TRACKER: #{block_count} consecutive blocks — releasing to break deadlock"
          )

          Logger.info("=== TASK COMPLETE (goal-tracker release) ===")
          state = State.reset_goal_blocks(state)
          {:done, {:ok, message}, state}
        else
          untouched =
            im.dependents
            |> Enum.reject(fn dep ->
              Enum.any?(
                MapSet.to_list(state.goal.modified_files),
                &String.contains?(&1, ToolDispatch.module_to_path(dep))
              )
            end)
            |> Enum.take(10)

          has_used_rename = Enum.any?(state.action_history, fn
            {:tool, "rename_mfa", _} -> true
            _ -> false
          end)

          rename_hint =
            if has_used_rename do
              "You already used rename_mfa earlier — use it again with the CORRECT arity to rename function definitions in all implementer modules."
            else
              "Use rename_mfa to rename function definitions across all implementers (this handles def/defp, @callback, and call sites atomically)."
            end

          lock_msg = """
          BLOCKED: You identified #{im.count} dependents of #{im.module} via get_impact_map, but you only modified #{touched} file(s).

          Untouched dependents (showing up to 10):
          #{Enum.map_join(untouched, "\n", &"  - #{&1}")}

          You MUST take action:
          1. #{rename_hint}
          2. Or use bulk_replace if you need simple string replacement across files.
          3. Or edit each remaining file individually.

          IMPORTANT: bulk_replace only matches exact strings. To rename function DEFINITIONS (def/defp), you MUST use rename_mfa.

          Do NOT call respond or think — take ACTION on the untouched files.
          """

          messages = state.messages ++ [%{role: "user", content: lock_msg}]
          state = State.set_messages(state, messages)
          {:next, :step, state}
        end

      true ->
        Logger.info("=== TASK COMPLETE ===")
        Logger.info("Iterations: #{State.iteration(state)}")
        Logger.info("Response: #{String.slice(message, 0, 300)}")
        {:done, {:ok, message}, state}
    end
  end

  defp handle_think(thought, response, state) do
    Logger.info("=== MODEL THINKING ===")
    Logger.info("Thought: #{String.slice(thought, 0, 300)}")

    think_count = ContextBuilder.count_recent_thinks(state.action_history)

    if think_count >= 2 do
      Logger.warning("Too many consecutive thinks (#{think_count}), forcing respond")

      nudge_msg =
        "You have been thinking too long. Use respond NOW to answer the user's question based on what you know."

      messages = state.messages ++ [%{role: "user", content: nudge_msg}]
      state = state |> State.set_messages(messages) |> State.reset_failures()
      {:next, :step, state}
    else
      assistant_msg =
        response.content || Jason.encode!(%{tool: "think", parameters: %{thought: thought}})

      messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]

      state = state
        |> State.set_messages(messages)
        |> State.reset_failures()
        |> State.record_action({"think", %{}, :ok})

      {:next, :step, state}
    end
  end

  defp handle_plain_text_response(text, response, state) do
    case StructuredOutput.extract_json(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, _parsed} ->
            handle_model_response(%{response | content: json}, state)

          {:error, _} ->
            {:done, {:ok, ResponseParser.clean_output(text)}, state}
        end

      {:error, _} ->
        {:done, {:ok, ResponseParser.clean_output(text)}, state}
    end
  end

  defp handle_json_escape_error(position, malformed_json, state) do
    Logger.info("=== JSON ESCAPE ERROR - REQUESTING RETRY ===")
    Logger.info("Error at position: #{position}")

    error_context = ResponseParser.extract_error_context(malformed_json, position)

    fix_message = """
    Your tool call failed to parse as valid JSON at position #{position}.
    Error context: ...#{error_context}...

    This is likely due to unescaped characters in your Elixir code (backticks `, quotes ", or newlines).
    In JSON strings, you must escape:
    - Backticks: No escaping needed, but avoid triple backticks
    - Quotes: Use \\"
    - Newlines: Use \\n
    - Backslashes: Use \\\\

    Please re-send the SAME tool call with properly escaped JSON.
    """

    messages = state.messages ++ [%{role: "user", content: fix_message}]

    state = state |> State.set_messages(messages) |> State.increment_failures()

    if State.max_failures?(state) do
      Logger.warning("Max JSON retries exceeded - giving up")
      {:next, :intervene, state}
    else
      Logger.info("Retrying after JSON escape error (attempt #{State.consecutive_failures(state)})")
      {:next, :step, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp call_provider(%{provider: %{module: module}, messages: messages}) do
    tools = Registry.list_tools()
    module.chat(messages, tools, timeout: 300_000)
  end

  defp check_baseline(state) do
    Verification.check_baseline(state.project_path, ContextBuilder.build_tool_opts(state))
  end

  defp resolve_provider(classification) do
    if Router.provider_available?(classification.provider) do
      {:ok, classification.provider, Router.get_provider_module(classification.provider)}
    else
      fallback = Router.fallback(classification.provider)

      if fallback && Router.provider_available?(fallback) do
        Logger.info("Using fallback provider: #{fallback}")
        {:ok, fallback, Router.get_provider_module(fallback)}
      else
        :no_provider
      end
    end
  end

  defp handle_native_command(prompt, state) do
    prompt_lower = String.downcase(prompt)
    project_path = state.project_path

    cond do
      String.contains?(prompt_lower, "module") ->
        modules = Store.list_modules(project_path)
        list = Enum.map_join(modules, "\n", &"- #{&1.name} (#{&1.file})")
        {:ok, "Indexed modules:\n#{list}"}

      String.contains?(prompt_lower, "function") ->
        functions = Store.list_functions(project_path)

        list =
          functions
          |> Enum.take(20)
          |> Enum.map_join("\n", &"- #{&1.module}.#{&1.name}/#{&1.arity}")

        {:ok, "Functions (first 20):\n#{list}"}

      String.contains?(prompt_lower, "status") ->
        stats = Store.stats(project_path)
        {:ok, "Index: #{stats.ast_files} files, #{stats.total_entries} entries"}

      String.contains?(prompt_lower, "summary") ->
        {:ok, Store.project_summary(project_path)}

      true ->
        {:ok, "Native command not recognized. Ask about modules, functions, status, or summary."}
    end
  end

  defp build_green_observation(tool_name, result, warnings, state, test_summary) do
    test_hint = ContextBuilder.build_test_hint(state)
    observation = Verification.build_green_observation(tool_name, result, warnings, test_hint, test_summary)
    messages = state.messages ++ [%{role: "user", content: observation}]
    state = State.set_messages(state, messages)
    {:next, :step, state}
  end

  defp goal_tracker_blocks?(state) do
    im = state.goal.last_impact_map
    touched = MapSet.size(state.goal.modified_files)
    im.count >= 3 and touched < div(im.count, 2)
  end

  defp broadcast_escalation_failed(state, message) do
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :escalation_failed,
        message: message
      })
    end
  end

  defp try_legacy_line_fix(response_text, target_file, provider_name, _errors, state) do
    case Escalation.parse_line_fix(response_text) do
      {:ok, line_num, fixed_line} ->
        Logger.info("Legacy fix: line #{line_num} -> #{String.slice(fixed_line, 0, 50)}...")

        tool_opts = ContextBuilder.build_tool_opts(state)
        sandbox = Keyword.get(tool_opts, :sandbox)

        case Escalation.apply_line_fix(target_file, line_num, fixed_line, sandbox) do
          {:ok, result} ->
            Logger.info("LEGACY FIX APPLIED: #{result}")

            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :escalation_complete,
                provider: provider_name,
                message: "#{provider_name} fixed line #{line_num} (legacy format)"
              })
            end

            state = state |> State.mark_escalated() |> State.set_syntax_failures(0) |> State.set_status(:thinking)
            {:next, {:verify, "write_file", {:ok, result}}, state}

          {:error, reason} ->
            Logger.error("Legacy line fix failed: #{inspect(reason)}")
            broadcast_escalation_failed(state, "All fix attempts failed")
            state = state |> State.mark_escalated() |> State.set_status(:thinking)
            {:next, :step, state}
        end

      {:error, _reason} ->
        Logger.error("No parseable fix in Senior Architect response")
        broadcast_escalation_failed(state, "Could not parse Senior Architect response")
        state = state |> State.mark_escalated() |> State.set_status(:thinking)
        {:next, :step, state}
    end
  end

  defp commit_integrity_check(staged_files, params, state) do
    staged_files
    |> Enum.filter(fn path ->
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")
    end)
    |> Enum.each(&Giulia.Context.Indexer.scan_file/1)

    Process.sleep(500)

    Giulia.Knowledge.Store.rebuild(state.project_path, Giulia.Context.Store.all_asts(state.project_path))

    if state.request_id do
      Events.broadcast(state.request_id, %{type: :commit_integrity_checking})
    end

    case Giulia.Knowledge.Store.check_all_behaviours(state.project_path) do
      {:ok, :consistent} ->
        Logger.info("COMMIT: Integrity check passed, running auto-regression")

        if state.request_id do
          Events.broadcast(state.request_id, %{type: :commit_integrity_passed})
        end

        commit_auto_regress(staged_files, params, state)

      {:error, fractures} ->
        Logger.warning("COMMIT: Integrity check FAILED — architectural fracture detected")
        state = State.set_transaction(state, Transaction.rollback(state.transaction, state.project_path))

        report = Transaction.format_fracture_report(fractures)

        error_msg = """
        COMMIT FAILED: ARCHITECTURAL FRACTURE — behaviour-implementer mismatch detected.
        All #{length(staged_files)} files have been ROLLED BACK to their original state.

        #{report}

        POST-ROLLBACK REALITY CHECK:
        Your changes compiled (syntax OK) but fractured the architecture (semantics BROKEN).
        A behaviour declares @callback functions that implementers MUST define.
        In your next transaction, ensure ALL implementers define the callbacks declared by their behaviour.
        Use get_impact_map to find all affected modules, then bulk_replace to fix consistently.
        """

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :architectural_fracture,
            reason: "behaviour_implementer_mismatch",
            message: "Behaviour-implementer mismatch — all changes rolled back",
            files: staged_files,
            fractures: report
          })
        end

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = State.set_messages(state, messages)
        {:next, :step, state}
    end
  end

  defp commit_auto_regress(staged_files, _params, state) do
    project_path = state.project_path || File.cwd!()
    tool_opts = ContextBuilder.build_tool_opts(state)

    all_test_targets =
      Enum.flat_map(staged_files, fn path ->
        case Store.find_module_by_file(project_path, path) do
          {:ok, %{name: module_name}} ->
            case Giulia.Knowledge.Store.get_test_targets(project_path, module_name) do
              {:ok, %{all_paths: paths}} when paths != [] -> paths
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    if all_test_targets != [] do
      Logger.info("COMMIT: Running #{length(all_test_targets)} regression test file(s)")

      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :commit_testing,
          test_count: length(all_test_targets)
        })
      end

      test_results =
        Enum.map(all_test_targets, fn test_path ->
          case Giulia.Tools.RunTests.execute(%{"file" => test_path}, tool_opts) do
            {:ok, output} -> {test_path, :ok, output}
            {:error, reason} -> {test_path, :error, inspect(reason)}
          end
        end)

      failures = Enum.filter(test_results, fn {_, status, _} -> status == :error end)

      if failures == [] do
        commit_success(state)
      else
        Logger.warning("COMMIT: Auto-regression failed, rolling back")
        state = State.set_transaction(state, Transaction.rollback(state.transaction, state.project_path))

        failure_summary =
          Enum.map_join(failures, "\n", fn {path, _, output} ->
            "  - #{path}: #{String.slice(output, 0, 200)}"
          end)

        error_msg = """
        COMMIT FAILED: Auto-regression tests failed. All changes have been ROLLED BACK.
        All #{length(staged_files)} files are back to their ORIGINAL state. Your staging buffer is cleared.

        Failed tests:
        #{failure_summary}

        POST-ROLLBACK REALITY CHECK:
        Your previous changes compiled but broke tests. Review the test failures above.
        In your next transaction, ensure your changes are consistent across ALL affected modules.
        Use bulk_replace for batch operations, then commit_changes to verify again.
        """

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :commit_rollback,
            reason: "test_failure",
            files: staged_files,
            message: "Auto-regression failed — all changes rolled back"
          })
        end

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = State.set_messages(state, messages)
        {:next, :step, state}
      end
    else
      commit_success(state)
    end
  end

  defp commit_success(state) do
    tx = state.transaction
    file_count = map_size(tx.staging_buffer)

    Logger.info("COMMIT: Success! #{file_count} file(s) committed")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :commit_success,
        file_count: file_count,
        files: Map.keys(tx.staging_buffer),
        message: "All #{file_count} file(s) verified and written to disk"
      })
    end

    observation = Transaction.success_report(tx)

    messages = state.messages ++ [%{role: "user", content: observation}]

    state = state
      |> State.set_messages(messages)
      |> State.set_transaction(Transaction.new())
      |> State.reset_failures()

    {:next, :step, state}
  end
end
