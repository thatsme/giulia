defmodule Giulia.Inference.Transaction do
  @moduledoc """
  Transactional Exoskeleton — Pure-functional staging logic.

  Manages a staging buffer for multi-file atomic changes:
  - Stage writes/edits in memory (no disk writes until commit)
  - AST tool staging via temp-file strategy
  - Read-with-overlay for staged content
  - Atomic commit with compile-verify-rollback
  - Integrity checks (behaviour-implementer contracts)
  - Auto-regression testing during commit

  All functions are pure — they take and return a `%State{}` struct
  (or components thereof) without GenServer coupling.
  """

  require Logger

  alias Giulia.Context.Store
  alias Giulia.Tools.Registry
  alias Giulia.Inference.Events

  # ============================================================================
  # Sub-struct: Transaction State
  # ============================================================================

  defstruct mode: false,
            staging_buffer: %{},
            staging_backups: %{},
            lock_count: 0

  @type t :: %__MODULE__{
          mode: boolean(),
          staging_buffer: %{String.t() => String.t()},
          staging_backups: %{String.t() => String.t() | :new_file},
          lock_count: non_neg_integer()
        }

  @doc """
  Create a new transaction state, optionally starting in transaction mode.
  """
  def new(mode \\ false) do
    %__MODULE__{mode: mode}
  end

  # ============================================================================
  # Staging Operations
  # ============================================================================

  @doc """
  Stage a write_file operation — store content in the staging buffer.
  Returns `{result, updated_tx}`.
  """
  def stage_write(tx, params, resolve_fn) do
    path = params["path"] || params[:path]
    content = params["content"] || params[:content] || ""
    resolved_path = resolve_fn.(path)

    tx = backup_original(tx, resolved_path)

    staging_buffer = Map.put(tx.staging_buffer, resolved_path, content)
    tx = %{tx | staging_buffer: staging_buffer}

    {{:ok, "#{path} (#{byte_size(content)} bytes)"}, tx}
  end

  @doc """
  Stage an edit_file operation — apply search/replace in memory using staged content as overlay.
  Returns `{result, updated_tx}`.
  """
  def stage_edit(tx, params, resolve_fn) do
    file = params["file"] || params[:file]
    old_text = params["old_text"] || params[:old_text] || ""
    new_text = params["new_text"] || params[:new_text] || ""
    resolved_path = resolve_fn.(file)

    current_content =
      case Map.get(tx.staging_buffer, resolved_path) do
        nil ->
          case File.read(resolved_path) do
            {:ok, content} -> content
            {:error, _} -> nil
          end

        staged ->
          staged
      end

    case current_content do
      nil ->
        {{:error, "File not found: #{file}"}, tx}

      content ->
        if String.contains?(content, old_text) do
          tx = backup_original(tx, resolved_path)

          new_content = String.replace(content, old_text, new_text, global: false)
          staging_buffer = Map.put(tx.staging_buffer, resolved_path, new_content)
          tx = %{tx | staging_buffer: staging_buffer}
          {{:ok, "#{file} (edit applied in staging)"}, tx}
        else
          {{:error, "old_text not found in #{file} (checked staging buffer)"}, tx}
        end
    end
  end

  @doc """
  Stage an AST tool (patch_function/write_function) via temp file strategy:
  1. Write staged content to disk temporarily
  2. Let the tool operate on it
  3. Read result back into staging buffer
  4. Restore original disk content
  Returns `{result, updated_tx}`.
  """
  def stage_ast(tx, tool_name, params, opts) do
    module = params["module"] || params[:module]
    project_path = Keyword.fetch!(opts, :project_path)
    resolve_fn = Keyword.fetch!(opts, :resolve_fn)
    tool_opts = Keyword.fetch!(opts, :tool_opts)

    case Store.find_module(project_path, module) do
      {:ok, %{file: file_path}} ->
        resolved_path = resolve_fn.(file_path)

        tx = backup_original(tx, resolved_path)

        # If we have staged content, write it to disk temporarily
        staged_content = Map.get(tx.staging_buffer, resolved_path)
        original_disk = if staged_content, do: File.read(resolved_path), else: nil

        if staged_content do
          File.write(resolved_path, staged_content)
        end

        # Let the AST tool operate on the (possibly temp) file
        result =
          try do
            Registry.execute(tool_name, params, tool_opts)
          rescue
            e -> {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
          end

        # Read the result back into staging regardless of success/failure
        case result do
          {:ok, _msg} ->
            case File.read(resolved_path) do
              {:ok, new_content} ->
                staging_buffer = Map.put(tx.staging_buffer, resolved_path, new_content)
                tx = %{tx | staging_buffer: staging_buffer}

                restore_disk_content(resolved_path, original_disk)

                {{:ok,
                  "#{module}.#{params["function_name"]}/#{params["arity"]} (AST patched in staging)"},
                 tx}

              {:error, read_err} ->
                restore_disk_content(resolved_path, original_disk)
                {{:error, "Failed to read back after #{tool_name}: #{inspect(read_err)}"}, tx}
            end

          {:error, reason} ->
            restore_disk_content(resolved_path, original_disk)
            {{:error, reason}, tx}
        end

      :not_found ->
        {{:error, "Module #{module} not found in index"}, tx}
    end
  end

  @doc """
  Read a file with staging overlay. Returns staged content if available, nil otherwise.
  """
  def read_with_overlay(tx, resolved_path) do
    Map.get(tx.staging_buffer, resolved_path)
  end

  @doc """
  Format the list of staged files for the model.
  """
  def format_staged_files(tx) do
    file_list =
      tx.staging_buffer
      |> Enum.map(fn {path, content} ->
        "  - #{path} (#{byte_size(content)} bytes)"
      end)
      |> Enum.sort()
      |> Enum.join("\n")

    count = map_size(tx.staging_buffer)

    if count == 0 do
      "No files staged. Transaction mode: #{tx.mode}"
    else
      "STAGED FILES (#{count}):\n#{file_list}\n\nTransaction mode: #{tx.mode}"
    end
  end

  # ============================================================================
  # Commit Logic
  # ============================================================================

  @doc """
  Run the integrity check phase — re-index files, rebuild knowledge graph,
  check behaviour-implementer contracts.
  Returns `:ok` or `{:error, fractures}`.
  """
  def integrity_check(staged_files, project_path, _opts) do
    # Re-index modified .ex/.exs files so ETS is fresh
    staged_files
    |> Enum.filter(fn path ->
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")
    end)
    |> Enum.each(&Giulia.Context.Indexer.scan_file/1)

    # Small delay for async scan_file casts to complete
    Process.sleep(500)

    # Rebuild knowledge graph with fresh data
    Giulia.Knowledge.Store.rebuild(project_path, Store.all_asts(project_path))

    # Check all behaviour-implementer contracts
    case Giulia.Knowledge.Store.check_all_behaviours(project_path) do
      {:ok, :consistent} -> :ok
      {:error, fractures} -> {:error, fractures}
    end
  end

  @doc """
  Run auto-regression tests for all modules affected by the staged files.
  Returns `{:ok, results}` or `{:error, failures, results}`.
  """
  def auto_regress(staged_files, project_path, tool_opts) do
    # Collect test targets for all modified modules
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

    if all_test_targets == [] do
      {:ok, :no_tests}
    else
      Logger.info("COMMIT: Running #{length(all_test_targets)} regression test file(s)")

      test_results =
        Enum.map(all_test_targets, fn test_path ->
          case Giulia.Tools.RunTests.execute(%{"file" => test_path}, tool_opts) do
            {:ok, output} -> {test_path, :ok, output}
            {:error, reason} -> {test_path, :error, inspect(reason)}
          end
        end)

      failures = Enum.filter(test_results, fn {_, status, _} -> status == :error end)

      if failures == [] do
        {:ok, test_results}
      else
        {:error, failures, test_results}
      end
    end
  end

  @doc """
  Build the commit success report.
  """
  def success_report(tx) do
    file_count = map_size(tx.staging_buffer)
    file_list = tx.staging_buffer |> Map.keys() |> Enum.map_join("\n", &"  - #{&1}")

    """
    COMMIT SUCCESS: #{file_count} file(s) atomically written to disk and verified.
    #{file_list}

    Build: GREEN. All changes are now on disk.
    """
  end

  @doc """
  Rollback all staged changes to their original state.
  Returns a new transaction state with empty staging fields.
  """
  def rollback(tx, project_path) do
    Enum.each(tx.staging_backups, fn
      {path, :new_file} ->
        File.rm(path)

      {path, original_content} when is_binary(original_content) ->
        File.write(path, original_content)
    end)

    count = map_size(tx.staging_backups)
    Logger.info("ROLLBACK: Restored #{count} file(s) to original state")

    # POST-ROLLBACK RE-VALIDATION: Recompile to resync the BEAM VM.
    Logger.info("ROLLBACK: Re-validating BEAM state (recompiling clean files)")

    case System.cmd("mix", ["compile", "--force"],
           cd: project_path || File.cwd!(),
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("ROLLBACK: BEAM re-validation succeeded — all modules reloaded")

      {output, _} ->
        Logger.warning(
          "ROLLBACK: BEAM re-validation had issues: #{String.slice(output, 0, 300)}"
        )
    end

    %{tx | staging_buffer: %{}, staging_backups: %{}}
  end

  @doc """
  Format a fracture report from behaviour-implementer mismatches.
  """
  def format_fracture_report(fractures) when is_map(fractures) do
    Enum.map_join(fractures, "\n\n", fn {behaviour, impl_fractures} ->
      impl_details =
        Enum.map_join(impl_fractures, "\n", fn %{implementer: impl, missing: missing} ->
          missing_str = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)
          "  - #{impl}: missing #{missing_str}"
        end)

      "BEHAVIOUR #{behaviour}:\n#{impl_details}"
    end)
  end

  @doc """
  Check if a write tool targets a hub module and auto-enable transaction mode.
  Returns updated transaction state and optionally updated max_iterations.
  """
  def maybe_auto_enable(tx, params, opts) do
    if tx.mode do
      {tx, nil}
    else
      tool_name = Keyword.fetch!(opts, :tool_name)
      project_path = Keyword.fetch!(opts, :project_path)
      resolve_module_fn = Keyword.fetch!(opts, :resolve_module_fn)
      request_id = Keyword.get(opts, :request_id)

      module_name = resolve_module_fn.(tool_name, params, project_path)

      if module_name do
        case Giulia.Knowledge.Store.centrality(project_path, module_name) do
          {:ok, %{in_degree: in_degree}} when in_degree >= 3 ->
            Logger.info(
              "TRANSACTION AUTO-ENABLED: #{module_name} is a hub (#{in_degree} dependents)"
            )

            if request_id do
              Events.broadcast(request_id, %{
                type: :transaction_auto_enabled,
                module: module_name,
                centrality: in_degree,
                message: "Transaction mode auto-enabled for hub module #{module_name}"
              })
            end

            {%{tx | mode: true}, 40}

          _ ->
            {tx, nil}
        end
      else
        {tx, nil}
      end
    end
  rescue
    _ -> {tx, nil}
  catch
    _, _ -> {tx, nil}
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  @doc """
  Backup original file content before first staging.
  """
  def backup_original(tx, resolved_path) do
    if Map.has_key?(tx.staging_backups, resolved_path) do
      tx
    else
      backup =
        case File.read(resolved_path) do
          {:ok, content} -> content
          {:error, :enoent} -> :new_file
          {:error, _} -> :new_file
        end

      %{tx | staging_backups: Map.put(tx.staging_backups, resolved_path, backup)}
    end
  end

  @doc false
  def restore_disk_content(_path, nil), do: :ok
  def restore_disk_content(path, {:ok, original}), do: File.write(path, original)
  def restore_disk_content(_path, {:error, _}), do: :ok
end
