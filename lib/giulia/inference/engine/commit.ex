defmodule Giulia.Inference.Engine.Commit do
  @moduledoc """
  Handles `{:commit_changes, params}` — the atomic write/compile/integrity/regress
  pipeline with rollback on failure.

  Extracted from Engine in build 112.
  """

  require Logger

  alias Giulia.Context.Store
  alias Giulia.Tools.Registry
  alias Giulia.Inference.{ContextBuilder, State, Transaction, Verification}
  alias Giulia.Inference.Engine.Helpers

  @doc """
  Run the commit pipeline: backup → write → compile → integrity → regress → success/rollback.
  """
  @spec run(map(), State.t()) :: Giulia.Inference.Engine.directive()
  def run(params, state) do
    tx = state.transaction
    staged_files = Map.keys(tx.staging_buffer)
    file_count = length(staged_files)
    message = params["message"] || "Committing #{file_count} staged file(s)"

    Logger.info("COMMIT: #{message}")
    Logger.info("COMMIT: Flushing #{file_count} file(s) to disk")

    Helpers.maybe_broadcast(state, %{
      type: :commit_started,
      file_count: file_count,
      files: staged_files,
      message: message
    })

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

      Helpers.maybe_broadcast(state, %{
        type: :commit_rollback,
        reason: "write_failure",
        files: staged_files,
        message: error_msg
      })

      messages = state.messages ++ [%{role: "user", content: error_msg}]
      state = State.set_messages(state, messages)
      {:next, :step, state}
    else
      # Phase 3: Compile
      Logger.info("COMMIT: Compile phase")
      tool_opts = ContextBuilder.build_tool_opts(state)

      Helpers.maybe_broadcast(state, %{type: :commit_compiling})

      case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
        {:ok, output} ->
          case Verification.parse_compile_result(output) do
            :success ->
              Logger.info("COMMIT: Compile passed, running integrity check")

              Helpers.maybe_broadcast(state, %{type: :commit_compile_passed})

              commit_integrity_check(staged_files, params, state)

            {:warnings, _warnings} ->
              Logger.info("COMMIT: Compile passed with warnings, running integrity check")

              Helpers.maybe_broadcast(state, %{type: :commit_compile_passed, warnings: true})

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

              Helpers.maybe_broadcast(state, %{
                type: :commit_rollback,
                reason: "compile_failure",
                message: "Compilation failed — all changes rolled back",
                files: staged_files,
                errors: String.slice(errors, 0, 500)
              })

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
  # Private
  # ============================================================================

  defp commit_integrity_check(staged_files, params, state) do
    staged_files
    |> Enum.filter(fn path ->
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")
    end)
    |> Enum.each(&Giulia.Context.Indexer.scan_file/1)

    Process.sleep(500)

    Giulia.Knowledge.Store.rebuild(state.project_path, Giulia.Context.Store.all_asts(state.project_path))

    Helpers.maybe_broadcast(state, %{type: :commit_integrity_checking})

    case Giulia.Knowledge.Store.check_all_behaviours(state.project_path) do
      {:ok, :consistent} ->
        Logger.info("COMMIT: Integrity check passed, running auto-regression")

        Helpers.maybe_broadcast(state, %{type: :commit_integrity_passed})

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

        Helpers.maybe_broadcast(state, %{
          type: :architectural_fracture,
          reason: "behaviour_implementer_mismatch",
          message: "Behaviour-implementer mismatch — all changes rolled back",
          files: staged_files,
          fractures: report
        })

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
        case Store.Query.find_module_by_file(project_path, path) do
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

      Helpers.maybe_broadcast(state, %{
        type: :commit_testing,
        test_count: length(all_test_targets)
      })

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

        Helpers.maybe_broadcast(state, %{
          type: :commit_rollback,
          reason: "test_failure",
          files: staged_files,
          message: "Auto-regression failed — all changes rolled back"
        })

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

    Helpers.maybe_broadcast(state, %{
      type: :commit_success,
      file_count: file_count,
      files: Map.keys(tx.staging_buffer),
      message: "All #{file_count} file(s) verified and written to disk"
    })

    observation = Transaction.success_report(tx)

    messages = state.messages ++ [%{role: "user", content: observation}]

    state = state
      |> State.set_messages(messages)
      |> State.set_transaction(Transaction.new())
      |> State.reset_failures()

    {:next, :step, state}
  end
end
