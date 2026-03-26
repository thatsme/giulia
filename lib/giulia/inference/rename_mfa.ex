defmodule Giulia.Inference.RenameMFA do
  @moduledoc """
  AST-based function rename across the codebase.

  Uses Sourceror to find exact line numbers of function definitions,
  call sites, and @callback declarations, then performs surgical
  string replacement to preserve formatting perfectly.

  Pure-functional module — takes data, returns results. No GenServer coupling.
  """

  require Logger

  alias Giulia.Context.Store
  alias Giulia.Inference.Transaction

  @doc """
  Execute a rename_mfa operation.

  Returns `{:ok, observation, new_tx, modified_files}` or `{:error, reason}`.

  Options:
    - `:project_path` — required
    - `:resolve_fn` — `fn path -> resolved_path end`
    - `:request_id` — for event broadcasting (optional)
  """
  @spec execute(map(), Transaction.t(), keyword()) ::
          {:ok, String.t(), Transaction.t(), MapSet.t(), map()} | {:error, String.t()}
  def execute(params, tx, opts) do
    module = params["module"] || params[:module]
    old_name = params["old_name"] || params[:old_name]
    new_name = params["new_name"] || params[:new_name]
    arity = params["arity"] || params[:arity]

    cond do
      is_nil(module) or module == "" ->
        {:error, "Missing required parameter: module"}

      is_nil(old_name) or old_name == "" ->
        {:error, "Missing required parameter: old_name"}

      is_nil(new_name) or new_name == "" ->
        {:error, "Missing required parameter: new_name"}

      is_nil(arity) ->
        {:error, "Missing required parameter: arity"}

      old_name == new_name ->
        {:error, "old_name and new_name are identical: #{old_name}"}

      true ->
        arity =
          if is_binary(arity) do
            case Integer.parse(arity) do
              {n, _} -> n
              :error -> 0
            end
          else
            arity
          end

        run(module, old_name, new_name, arity, tx, opts)
    end
  end

  @doc false
  @spec run(String.t(), String.t(), String.t(), non_neg_integer(), term(), keyword()) ::
          {:ok, String.t(), term(), MapSet.t()} | {:error, String.t()}
  def run(module, old_name, new_name, arity, tx, opts) do
    project_path = Keyword.fetch!(opts, :project_path)
    resolve_fn = Keyword.fetch!(opts, :resolve_fn)
    modified_files = Keyword.get(opts, :modified_files, MapSet.new())

    old_atom = String.to_existing_atom(old_name)

    # === PHASE 1: Discovery via Knowledge Graph + ETS ===
    Logger.info("RENAME_MFA: Phase 1 — Discovery for #{module}.#{old_name}/#{arity}")

    all_modules = Store.Query.list_modules(project_path)
    target_entry = Enum.find(all_modules, fn m -> m.name == module end)

    if is_nil(target_entry) do
      {:error, "Module '#{module}' not found in index. Run /scan first."}
    else
      target_resolved = resolve_fn.(target_entry.file)

      target_source =
        case Map.get(tx.staging_buffer, target_resolved) do
          nil ->
            case File.read(target_resolved) do
              {:ok, c} -> c
              _ -> ""
            end

          staged ->
            staged
        end

      arity_range = detect_arity_range(target_source, old_atom, arity)

      Logger.info(
        "RENAME_MFA: Arity range: #{inspect(arity_range)} (default args detected: #{length(arity_range) > 1})"
      )

      # Get dependents (callers) from Knowledge Graph
      callers =
        case Giulia.Knowledge.Store.dependents(project_path, module) do
          {:ok, deps} -> deps
          {:error, _} -> []
        end

      # Get implementers ONLY if old_name is a declared @callback
      callbacks = Store.Query.list_callbacks(project_path, module)

      is_callback =
        Enum.any?(callbacks, fn cb ->
          cb_name = if is_atom(cb.function), do: Atom.to_string(cb.function), else: cb.function
          cb_name == old_name and cb.arity in arity_range
        end)

      implementers =
        if is_callback do
          case get_implementers_from_graph(project_path, module) do
            {:ok, impls} -> impls
            _ -> []
          end
        else
          Logger.info(
            "RENAME_MFA: #{old_name} is NOT a @callback in #{module} — skipping implementers"
          )

          []
        end

      implementer_callers =
        if is_callback do
          Enum.flat_map(implementers, fn impl ->
            case Giulia.Knowledge.Store.dependents(project_path, impl) do
              {:ok, deps} -> deps
              _ -> []
            end
          end)
        else
          []
        end

      affected_modules =
        Enum.uniq([module] ++ callers ++ implementers ++ implementer_callers)

      affected_files =
        all_modules
        |> Enum.filter(fn m -> m.name in affected_modules end)
        |> Enum.map(fn m -> m.file end)
        |> Enum.uniq()

      Logger.info(
        "RENAME_MFA: #{length(affected_files)} files to scan " <>
          "(#{length(callers)} callers, #{length(implementers)} implementers, #{length(implementer_callers)} impl_callers)"
      )

      # === PHASE 2: AST-guided line-level rename in each file ===
      {tx, modified_files, results} =
        Enum.reduce(affected_files, {tx, modified_files, []}, fn file_path,
                                                                 {acc_tx, acc_mf, acc} ->
          resolved = resolve_fn.(file_path)

          content =
            case Map.get(acc_tx.staging_buffer, resolved) do
              nil ->
                case File.read(resolved) do
                  {:ok, c} -> c
                  {:error, reason} -> {:error, reason}
                end

              staged ->
                staged
            end

          case content do
            {:error, reason} ->
              {acc_tx, acc_mf, [{file_path, {:error, "Cannot read: #{inspect(reason)}"}} | acc]}

            source ->
              modules_in_file =
                all_modules
                |> Enum.filter(fn m -> m.file == file_path end)
                |> Enum.map(fn m -> m.name end)

              is_target = module in modules_in_file
              is_impl = Enum.any?(modules_in_file, fn m -> m in implementers end)
              is_caller = Enum.any?(modules_in_file, fn m -> m in callers end)

              {new_source, changes} =
                rename_in_source(source, module, old_atom, old_name, new_name, arity_range,
                  is_target: is_target,
                  is_implementer: is_impl,
                  is_caller: is_caller,
                  implementer_modules: implementers
                )

              if changes > 0 do
                new_tx = Transaction.backup_original(acc_tx, resolved)
                staging_buffer = Map.put(new_tx.staging_buffer, resolved, new_source)
                new_tx = %{new_tx | staging_buffer: staging_buffer}
                new_mf = MapSet.put(acc_mf, resolved)
                {new_tx, new_mf, [{file_path, {:ok, changes}} | acc]}
              else
                {acc_tx, acc_mf, [{file_path, :no_match} | acc]}
              end
          end
        end)

      # === PHASE 3: Build report ===
      staged = Enum.reverse(Enum.filter(results, fn {_, r} -> match?({:ok, _}, r) end))
      skipped = Enum.reverse(Enum.filter(results, fn {_, r} -> r == :no_match end))
      errors = Enum.reverse(Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end))

      total_changes = Enum.reduce(staged, 0, fn {_, {:ok, c}}, acc -> acc + c end)

      staged_summary =
        Enum.map_join(staged, "\n", fn {file, {:ok, count}} ->
          "  [STAGED] #{Path.basename(file)} (#{count} rename#{if count > 1, do: "s", else: ""})"
        end)

      skipped_summary =
        if skipped != [] do
          "\nSkipped (no matches):\n" <>
            Enum.map_join(skipped, "\n", fn {f, _} -> "  - #{Path.basename(f)}" end)
        else
          ""
        end

      error_summary =
        if errors != [] do
          "\nErrors:\n" <>
            Enum.map_join(errors, "\n", fn {f, {:error, r}} -> "  - #{Path.basename(f)}: #{r}" end)
        else
          ""
        end

      observation =
        if staged == [] do
          """
          [RENAME_MFA] FAILED: #{module}.#{old_name}/#{arity} → #{new_name}
          0 renames across #{length(affected_files)} files.
          Callers found: #{length(callers)}, Implementers: #{length(implementers)}
          Arity range: #{inspect(arity_range)}
          #{error_summary}

          HINT: Verify the function exists with get_module_info or lookup_function.
          """
        else
          """
          [RENAME_MFA] #{module}.#{old_name}/#{arity} → #{new_name}
          #{length(staged)} file(s) staged, #{total_changes} total renames
          Arity range: #{inspect(arity_range)}

          Staged:
          #{staged_summary}#{skipped_summary}#{error_summary}

          Discovery: #{length(callers)} callers, #{length(implementers)} implementers
          Currently staging #{map_size(tx.staging_buffer)} file(s) total. Use commit_changes to flush.
          """
        end

      Logger.info("RENAME_MFA: #{length(staged)} files staged, #{total_changes} renames")

      {:ok, String.trim(observation), tx, modified_files,
       %{
         staged: staged,
         total_changes: total_changes,
         arity: arity,
         module: module,
         old_name: old_name,
         new_name: new_name
       }}
    end
  end

  # ============================================================================
  # AST Helpers (Pure Functions)
  # ============================================================================

  @doc """
  Detect default arguments and return the range of valid arities.
  e.g., `def execute(name, args, opts \\\\ [])` → `[2, 3]`
  """
  @spec detect_arity_range(String.t(), atom(), non_neg_integer()) :: [non_neg_integer()]
  def detect_arity_range(source, old_atom, declared_arity) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, {max_total_arity, max_defaults}} =
          Macro.prewalk(ast, {0, 0}, fn
            {def_type, _meta, [{^old_atom, _fn_meta, args} | _]} = node, {max_a, max_d}
            when def_type in [:def, :defp] and is_list(args) ->
              total = length(args)

              defaults =
                Enum.count(args, fn
                  {:\\, _, _} -> true
                  _ -> false
                end)

              {node, {max(max_a, total), max(max_d, defaults)}}

            node, acc ->
              {node, acc}
          end)

        max_arity = max(declared_arity, max_total_arity)
        min_arity = min(declared_arity, max_arity - max_defaults)
        min_arity = max(min_arity, 0)
        Enum.to_list(min_arity..max_arity)

      _ ->
        [declared_arity]
    end
  end

  @doc """
  AST-guided, line-level rename within a single source file.
  Returns `{new_source, change_count}`.
  """
  @spec rename_in_source(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          String.t(),
          [non_neg_integer()],
          keyword()
        ) ::
          {String.t(), non_neg_integer()}
  def rename_in_source(source, target_module, old_atom, old_name, new_name, arity_range, opts) do
    is_target = Keyword.get(opts, :is_target, false)
    is_implementer = Keyword.get(opts, :is_implementer, false)
    _is_caller = Keyword.get(opts, :is_caller, false)
    implementer_modules = Keyword.get(opts, :implementer_modules, [])

    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, raw_targets} =
          Macro.prewalk(ast, [], fn node, acc ->
            case node do
              {def_type, _meta, [{^old_atom, fn_meta, args} | _]}
              when def_type in [:def, :defp] and (is_target or is_implementer) ->
                if length(args || []) in arity_range do
                  {node, [{fn_meta[:line], :def} | acc]}
                else
                  {node, acc}
                end

              {:@, _attr_meta,
               [
                 {:callback, _cb_meta,
                  [{:"::", _spec_meta, [{^old_atom, fn_meta, args} | _]} | _]}
               ]}
              when is_target ->
                if length(args || []) in arity_range do
                  {node, [{fn_meta[:line], :callback} | acc]}
                else
                  {node, acc}
                end

              {{:., _dot_meta2, [{_var, _var_meta, ctx}, ^old_atom]}, call_meta, args}
              when is_target and is_atom(ctx) ->
                if length(args || []) in arity_range do
                  {node, [{call_meta[:line], :dynamic_call} | acc]}
                else
                  {node, acc}
                end

              {{:., _dot_meta, [alias_node, ^old_atom]}, call_meta, args} ->
                if length(args || []) in arity_range and
                     (ast_matches_module?(alias_node, target_module) or
                        ast_matches_any_module?(alias_node, implementer_modules)) do
                  {node, [{call_meta[:line], :remote_call} | acc]}
                else
                  {node, acc}
                end

              {^old_atom, call_meta, args}
              when (is_target or is_implementer) and is_list(args) ->
                if length(args) in arity_range do
                  {node, [{call_meta[:line], :local_call} | acc]}
                else
                  {node, acc}
                end

              _ ->
                {node, acc}
            end
          end)

        target_lines =
          raw_targets
          |> Enum.map(fn {line, _type} -> line end)
          |> Enum.uniq()
          |> MapSet.new()

        if MapSet.size(target_lines) == 0 do
          {source, 0}
        else
          {new_lines, count} =
            source
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.map_reduce(0, fn {line, num}, acc ->
              if MapSet.member?(target_lines, num) do
                new_line = rename_on_line(line, old_name, new_name)

                if new_line != line do
                  {new_line, acc + 1}
                else
                  {line, acc}
                end
              else
                {line, acc}
              end
            end)

          {Enum.join(new_lines, "\n"), count}
        end

      {:error, _} ->
        Logger.warning("RENAME_MFA: Sourceror parse failed, skipping file")
        {source, 0}
    end
  end

  @doc """
  Replace function name on a specific line using word-boundary regex.
  """
  @spec rename_on_line(String.t(), String.t(), String.t()) :: String.t()
  def rename_on_line(line, old_name, new_name) do
    Regex.replace(~r/\b#{Regex.escape(old_name)}\(/, line, "#{new_name}(")
  end

  @doc false
  @spec ast_matches_module?(term(), String.t()) :: boolean()
  def ast_matches_module?({:__aliases__, _meta, parts}, target_module) when is_list(parts) do
    alias_str = Enum.map_join(parts, ".", &Atom.to_string/1)

    alias_str == target_module or
      Atom.to_string(List.last(parts)) == last_segment(target_module)
  end

  def ast_matches_module?(atom, target_module) when is_atom(atom) do
    Atom.to_string(atom) == target_module or
      Atom.to_string(atom) == last_segment(target_module)
  end

  def ast_matches_module?(_, _), do: false

  @doc false
  @spec ast_matches_any_module?(term(), list()) :: boolean()
  def ast_matches_any_module?(_alias_node, []), do: false

  def ast_matches_any_module?(alias_node, modules) do
    Enum.any?(modules, &ast_matches_module?(alias_node, &1))
  end

  @doc false
  @spec last_segment(String.t()) :: String.t()
  def last_segment(module_name) do
    List.last(String.split(module_name, "."))
  end

  @doc false
  @spec get_implementers_from_graph(String.t(), String.t()) :: {:ok, list()} | {:error, term()}
  def get_implementers_from_graph(project_path, behaviour_module) do
    try do
      GenServer.call(Giulia.Knowledge.Store, {:get_implementers, project_path, behaviour_module})
    catch
      :exit, reason ->
        Logger.warning("get_implementers_from_graph exit: #{inspect(reason)}")
        {:ok, []}
    end
  end
end
