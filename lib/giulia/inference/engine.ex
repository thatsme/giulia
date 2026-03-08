defmodule Giulia.Inference.Engine do
  @moduledoc """
  Inference loop core — the "brain" of the inference pipeline.

  Receives actions from the Orchestrator's handle_continue, performs them
  (including side effects like provider calls), and returns directives.

  Directive types:
    {:next, action, state}  — continue to next inference step
    {:done, result, state}  — task complete, reply to caller
    {:halt, state}          — wait (paused, waiting for approval)

  Extracted from Orchestrator in build 84.
  Split into sub-modules in build 112:
    - Engine.Helpers   — shared telemetry/broadcast/observation helpers
    - Engine.Startup   — {:start, prompt, opts} flow
    - Engine.Step      — :step guards + normal LLM call
    - Engine.Response  — model response parsing + gate enforcement
    - Engine.Commit    — {:commit_changes} atomic pipeline
  """

  require Logger

  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.StructuredOutput.Parser
  alias Giulia.Core.ProjectContext
  alias Giulia.Inference.{
    ContextBuilder, Escalation, State, Verification
  }
  alias Giulia.Inference.Engine.{Commit, Helpers, Startup, Step}

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
  def dispatch({:start, prompt, opts}, state), do: Startup.run(prompt, opts, state)

  # ---------- STEP ----------
  def dispatch(:step, state), do: Step.run(state)

  # ---------- COMMIT ----------
  def dispatch({:commit_changes, params}, state), do: Commit.run(params, state)

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

    Helpers.maybe_broadcast(state, %{
      type: :escalation_started,
      message: "Senior Architect analyzing error (v2 hybrid)..."
    })

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

                Helpers.maybe_broadcast(state, %{
                  type: :escalation_complete,
                  provider: provider_name,
                  message: "#{provider_name} applied #{tool_name}: #{success_msg}"
                })

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

                Helpers.broadcast_escalation_failed(
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

        Helpers.maybe_broadcast(state, %{
          type: :escalation_failed,
          message: "Could not reach Senior Architect: #{inspect(reason)}"
        })

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

    Helpers.maybe_broadcast(state, %{
      type: :verification_started,
      tool: tool_name,
      message: "Running mix compile..."
    })

    tool_opts = ContextBuilder.build_tool_opts(state)

    case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
      {:ok, output} ->
        case Verification.parse_compile_result(output) do
          :success ->
            Logger.info("Verification passed")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            Helpers.maybe_broadcast(state, %{
              type: :verification_passed,
              tool: tool_name,
              message: "Build successful"
            })

            state = State.set_pending_verification(state, false)
            {:next, {:auto_regress, tool_name, result, nil}, state}

          {:warnings, warnings} ->
            Logger.info("Verification passed with warnings")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            Helpers.maybe_broadcast(state, %{
              type: :verification_passed,
              tool: tool_name,
              message: "Build successful (with warnings)",
              warnings: String.slice(warnings, 0, 200)
            })

            state = State.set_pending_verification(state, false)
            {:next, {:auto_regress, tool_name, result, warnings}, state}

          {:error, errors} ->
            Logger.warning("Verification failed - compilation error")
            if state.project_pid, do: ProjectContext.mark_verification_failed(state.project_pid)

            state = State.increment_syntax_failures(state)
            new_syntax_failures = State.syntax_failures(state)
            Logger.info("Syntax failure count: #{new_syntax_failures}")

            Helpers.maybe_broadcast(state, %{
              type: :verification_failed,
              tool: tool_name,
              message: "BUILD BROKEN - Model must fix (attempt #{new_syntax_failures})",
              errors: String.slice(errors, 0, 500)
            })

            total_failures = new_syntax_failures + State.consecutive_failures(state)

            if (new_syntax_failures >= 2 or total_failures >= 2) and not State.escalated?(state) do
              Logger.warning(
                "HYBRID ESCALATION: Local model failed #{new_syntax_failures} times, calling Sonnet"
              )

              Helpers.maybe_broadcast(state, %{
                type: :escalation_triggered,
                message: "Calling Senior Architect for assistance..."
              })

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

          case Giulia.Context.Store.find_module_by_file(state.project_path, path || "") do
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

      Helpers.maybe_broadcast(state, %{
        type: :auto_regression_started,
        module: module_name,
        test_files: test_targets
      })

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

        Helpers.maybe_broadcast(state, %{
          type: :auto_regression_passed,
          module: module_name,
          test_count: length(test_targets)
        })

        test_summary =
          Enum.map_join(test_results, "\n", fn {path, _, output} ->
            "  ✅ #{path}: #{String.slice(output, 0, 80)}"
          end)

        Helpers.build_green_observation(tool_name, result, warnings, state, test_summary)
      else
        Logger.warning("AUTO-REGRESSION: #{length(failures)} test file(s) failed")
        state = State.set_test_status(state, :red)

        Helpers.maybe_broadcast(state, %{
          type: :auto_regression_failed,
          module: module_name,
          failed_count: length(failures)
        })

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
      Helpers.build_green_observation(tool_name, result, warnings, state, nil)
    end
  end

  # ============================================================================
  # Private Helpers (kept in facade — tightly coupled to :escalate)
  # ============================================================================

  defp try_legacy_line_fix(response_text, target_file, provider_name, _errors, state) do
    case Escalation.parse_line_fix(response_text) do
      {:ok, line_num, fixed_line} ->
        Logger.info("Legacy fix: line #{line_num} -> #{String.slice(fixed_line, 0, 50)}...")

        tool_opts = ContextBuilder.build_tool_opts(state)
        sandbox = Keyword.get(tool_opts, :sandbox)

        case Escalation.apply_line_fix(target_file, line_num, fixed_line, sandbox) do
          {:ok, result} ->
            Logger.info("LEGACY FIX APPLIED: #{result}")

            Helpers.maybe_broadcast(state, %{
              type: :escalation_complete,
              provider: provider_name,
              message: "#{provider_name} fixed line #{line_num} (legacy format)"
            })

            state = state |> State.mark_escalated() |> State.set_syntax_failures(0) |> State.set_status(:thinking)
            {:next, {:verify, "write_file", {:ok, result}}, state}

          {:error, reason} ->
            Logger.error("Legacy line fix failed: #{inspect(reason)}")
            Helpers.broadcast_escalation_failed(state, "All fix attempts failed")
            state = state |> State.mark_escalated() |> State.set_status(:thinking)
            {:next, :step, state}
        end

      {:error, _reason} ->
        Logger.error("No parseable fix in Senior Architect response")
        Helpers.broadcast_escalation_failed(state, "Could not parse Senior Architect response")
        state = state |> State.mark_escalated() |> State.set_status(:thinking)
        {:next, :step, state}
    end
  end
end
