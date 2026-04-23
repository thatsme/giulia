defmodule Giulia.Knowledge.Conventions do
  @moduledoc """
  Convention violation detection via AST analysis.

  Checks Elixir source files against a defined set of coding conventions,
  returning structured violations grouped by rule, category, severity, and file.

  Two tiers of checks:
  - **Tier 1 (Metadata)**: Uses already-indexed ETS data (specs, docs, structs, functions).
    No file I/O or AST parsing required.
  - **Tier 2 (AST Pattern)**: Reads source files and walks the Sourceror AST with
    `Macro.prewalk/3` to detect anti-patterns.

  All functions are stateless — they take a `project_path` and return computed results.
  """

  # OTP/framework callbacks that should be excluded from missing @spec checks.
  # These have their specs defined by the behaviour — flagging them is a false positive.
  @implicit_callbacks MapSet.new([
    # GenServer / Supervisor / Application
    {:init, 1}, {:handle_call, 3}, {:handle_cast, 2}, {:handle_info, 2},
    {:handle_continue, 2}, {:terminate, 2}, {:code_change, 3},
    {:config_change, 3}, {:start, 2}, {:stop, 1}, {:child_spec, 1},
    {:start_link, 0}, {:start_link, 1},
    # Plug / Phoenix
    {:call, 2}, {:mount, 3}, {:render, 1},
    {:handle_event, 3}, {:handle_params, 3}, {:handle_async, 3},
    {:handle_in, 3}, {:handle_out, 3},
    {:join, 3}, {:connect, 2}, {:id, 1},
    # Ecto
    {:changeset, 1}, {:changeset, 2},
    # Escript / Mix tasks
    {:main, 1}, {:run, 1},
    # Tool/framework conventions
    {:name, 0}, {:description, 0}, {:parameters, 0}
  ])

  # ============================================================================
  # Public API
  # ============================================================================

  @spec conventions(String.t(), keyword()) :: {:ok, map()}
  def conventions(project_path, opts \\ [])

  def conventions(project_path, opts) when is_list(opts) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    suppress = Keyword.get(opts, :suppress, %{})
    module_filter = Keyword.get(opts, :module)

    violations =
      tier1_checks(all_asts, project_path) ++ tier2_checks(all_asts, project_path)

    violations = apply_suppressions(violations, suppress)

    violations =
      if module_filter do
        Enum.filter(violations, fn v -> v.module == module_filter end)
      else
        violations
      end

    by_severity = Enum.frequencies_by(violations, & &1.severity)
    by_category = violations |> Enum.group_by(& &1.category) |> sort_groups()

    by_file =
      violations
      |> Enum.group_by(& &1.file)
      |> Enum.sort_by(fn {_file, vs} -> -length(vs) end)
      |> Enum.map(fn {file, vs} -> {file, Enum.sort_by(vs, & &1.line)} end)
      |> Map.new()

    result = %{
      total_violations: length(violations),
      by_severity: %{
        error: Map.get(by_severity, "error", 0),
        warning: Map.get(by_severity, "warning", 0),
        info: Map.get(by_severity, "info", 0)
      },
      by_category: by_category,
      by_file: by_file,
      rules_checked: rules_checked()
    }

    result = if module_filter, do: Map.put(result, :module_filter, module_filter), else: result
    result = if suppress != %{}, do: Map.put(result, :suppressions_applied, suppress), else: result

    {:ok, result}
  end

  # Backwards-compatible 2-arity: conventions(path, module_filter_string)
  def conventions(project_path, module_filter) when is_binary(module_filter) do
    conventions(project_path, module: module_filter)
  end

  # ============================================================================
  # Tier 1 — Metadata Checks (ETS data only, no file I/O)
  # ============================================================================

  defp tier1_checks(all_asts, project_path) do
    Enum.flat_map(all_asts, fn {file, data} ->
      modules = data[:modules] || []
      functions = data[:functions] || []
      specs = data[:specs] || []
      structs = data[:structs] || []

      module_name = first_module_name(modules)

      check_missing_moduledoc(modules, file) ++
        check_missing_specs(functions, specs, modules, file) ++
        check_missing_enforce_keys(structs, file, module_name, project_path)
    end)
  end

  # Rule: Every module gets @moduledoc
  # Note: @moduledoc false is a valid declaration ("intentionally undocumented")
  defp check_missing_moduledoc(modules, file) do
    modules
    |> Enum.filter(fn m ->
      doc = m[:moduledoc] || m.moduledoc
      is_nil(doc) or doc == ""
    end)
    |> Enum.map(fn m ->
      violation(
        rule: "missing_moduledoc",
        message: "Module #{m.name} has no @moduledoc",
        category: "documentation",
        severity: "warning",
        file: file,
        line: m[:line] || m.line,
        module: m.name,
        convention_ref: "Typespecs and Documentation > Every module gets @moduledoc"
      )
    end)
  end

  # Rule: Every public function gets @spec
  defp check_missing_specs(functions, specs, modules, file) do
    module_name = first_module_name(modules)

    spec_set =
      specs
      |> Enum.map(fn s -> {s.function, s.arity} end)
      |> MapSet.new()

    functions
    |> Enum.filter(fn f -> f.type == :def end)
    |> Enum.reject(fn f -> MapSet.member?(@implicit_callbacks, {f.name, f.arity}) end)
    |> Enum.reject(fn f -> MapSet.member?(spec_set, {f.name, f.arity}) end)
    |> Enum.reject(fn f -> String.starts_with?(to_string(f.name), "__") end)
    |> Enum.map(fn f ->
      violation(
        rule: "missing_spec",
        message: "#{module_name}.#{f.name}/#{f.arity} has no @spec",
        category: "documentation",
        severity: "warning",
        file: file,
        line: f[:line] || f.line,
        module: module_name,
        convention_ref: "Typespecs and Documentation > Every public function gets @spec"
      )
    end)
  end

  # Rule: Use @enforce_keys for required struct fields
  # NOTE: The ETS module_info type does not store module attributes, so we cannot
  # rely on m[:attributes] here. Instead we read the source file directly to check
  # for the presence of `@enforce_keys` — this is a single File.read per file and
  # only fires when the indexed data reports at least one defstruct in the file.
  defp check_missing_enforce_keys(structs, file, module_name, project_path) do
    if structs != [] do
      resolved = resolve_file_path(file, project_path)

      has_enforce =
        case File.read(resolved) do
          {:ok, source} -> String.contains?(source, "@enforce_keys")
          _ -> false
        end

      if has_enforce do
        []
      else
        Enum.map(structs, fn s ->
          struct_mod = s[:module] || module_name

          violation(
            rule: "missing_enforce_keys",
            message: "Struct #{struct_mod} has no @enforce_keys — required fields are not enforced at compile time",
            category: "structs",
            severity: "info",
            file: file,
            line: s[:line] || 1,
            module: struct_mod,
            convention_ref: "Structs and Maps > Use @enforce_keys for required fields"
          )
        end)
      end
    else
      []
    end
  end

  # ============================================================================
  # Tier 2 — AST Pattern Checks (Sourceror parse + Macro.prewalk)
  # ============================================================================

  defp tier2_checks(all_asts, project_path) do
    Enum.flat_map(all_asts, fn {file, data} ->
      # Resolve the actual file path for reading
      resolved = resolve_file_path(file, project_path)
      module_name = first_module_name(data[:modules] || [])

      case File.read(resolved) do
        {:ok, source} ->
          case Sourceror.parse_string(source) do
            {:ok, ast} -> walk_ast(ast, file, module_name)
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc false
  def walk_ast(ast, file, module_name) do
    {_ast, violations} =
      Macro.prewalk(ast, %{violations: [], context: []}, fn node, acc ->
        new_violations =
          check_try_rescue_flow_control(node, file, module_name) ++
            check_silent_rescue(node, file, module_name) ++
            check_string_to_atom(node, file, module_name) ++
            check_process_dictionary(node, file, module_name) ++
            check_task_start_unsupervised(node, file, module_name) ++
            check_unless_else(node, file, module_name) ++
            check_append_in_reduce(node, file, module_name) ++
            check_if_not(node, file, module_name)

        {node, %{acc | violations: acc.violations ++ new_violations}}
      end)

    # Single-value pipe check done separately — needs parent context to avoid
    # false positives on chain members (conn |> A |> B wrongly flagging inner |>)
    pipe_violations = check_single_value_pipes(ast, file, module_name)

    violations.violations ++ pipe_violations
  end

  # Rule: Use Repo.get not Repo.get! + rescue / Use Integer.parse not String.to_integer + rescue
  #
  # The detection walks the try's `:do` body AST looking for actual call
  # sites of the banned functions. An earlier implementation used
  # `String.contains?(Macro.to_string(node), "Repo.get!")` which matched
  # on string literals, function captures, and variable-name fragments
  # inside the try body — silent over-match. See
  # `test/giulia/knowledge/conventions_test.exs` for the regression
  # fixtures.
  defp check_try_rescue_flow_control({:try, meta, [clauses]}, file, module_name)
       when is_list(clauses) do
    body = get_try_clause(clauses, :do)
    rescues = get_try_clause(clauses, :rescue)

    if body != nil and is_list(rescues) and rescues != [] do
      cond do
        try_body_calls?(body, [:Repo], :get!) ->
          [violation(
            rule: "try_rescue_flow_control",
            message: "Repo.get! inside try/rescue — use Repo.get/2 + case instead",
            category: "error_handling",
            severity: "error",
            file: file,
            line: meta[:line] || 0,
            module: module_name,
            convention_ref: "Error Handling > Use Repo.get not Repo.get! + rescue"
          )]

        try_body_calls?(body, [:String], :to_integer) ->
          [violation(
            rule: "try_rescue_flow_control",
            message: "String.to_integer inside try/rescue — use Integer.parse/1 instead",
            category: "error_handling",
            severity: "error",
            file: file,
            line: meta[:line] || 0,
            module: module_name,
            convention_ref: "Error Handling > Use Integer.parse not String.to_integer + rescue"
          )]

        try_body_calls?(body, [:String], :to_float) ->
          [violation(
            rule: "try_rescue_flow_control",
            message: "String.to_float inside try/rescue — use Float.parse/1 instead",
            category: "error_handling",
            severity: "error",
            file: file,
            line: meta[:line] || 0,
            module: module_name,
            convention_ref: "Error Handling > Use Integer.parse not String.to_integer + rescue"
          )]

        true ->
          []
      end
    else
      []
    end
  end

  defp check_try_rescue_flow_control(_node, _file, _module), do: []

  # Sourceror wraps keyword keys in `{:__block__, meta, [atom]}` tuples
  # instead of bare atoms, so `Keyword.get/2` does not find them. Handle
  # both shapes: the `:do`/`:rescue` clause keys from Sourceror-parsed
  # source, and the bare-atom form that `Code.string_to_quoted/1` emits.
  defp get_try_clause(clauses, key) do
    Enum.find_value(clauses, fn
      {{:__block__, _, [^key]}, value} -> value
      {^key, value} -> value
      _ -> false
    end)
  end

  # Returns true iff `body_ast` contains a direct call node matching
  # `Module.func(arg, ...)` with at least one argument. Skips capture
  # expressions (`&Mod.f/n` and `&(...)`) because a call inside a
  # capture is deferred — it is not evaluated inside the enclosing try.
  defp try_body_calls?(body_ast, module_aliases, func) when is_list(module_aliases) do
    {_ast, found} =
      Macro.prewalk(body_ast, false, fn
        node, true ->
          {node, true}

        {:&, _, _}, false ->
          {[], false}

        {{:., _, [{:__aliases__, _, ^module_aliases}, ^func]}, _, args} = node, false
        when is_list(args) and args != [] ->
          {node, true}

        node, false ->
          {node, false}
      end)

    found
  end

  # Rule: Never swallow errors silently (rescue _ -> nil)
  defp check_silent_rescue({:try, meta, [body]} = _node, file, module_name) do
    rescues = get_in_keyword(body, :rescue) || []

    has_silent_catch_all =
      Enum.any?(rescues, fn
        {:->, _, [[{:_, _, _}], nil]} -> true
        {:->, _, [[{:_, _, _}], {:nil, _, _}]} -> true
        _ -> false
      end)

    if has_silent_catch_all do
      [violation(
        rule: "silent_rescue",
        message: "Silent rescue _ -> nil swallows errors — log or let it crash",
        category: "error_handling",
        severity: "error",
        file: file,
        line: meta[:line] || 0,
        module: module_name,
        convention_ref: "Error Handling > Never swallow errors silently"
      )]
    else
      []
    end
  end

  defp check_silent_rescue(_node, _file, _module), do: []

  # Rule: Never create atoms from runtime strings
  defp check_string_to_atom({{:., meta, [{:__aliases__, _, [:String]}, :to_atom]}, _, _}, file, module_name) do
    [violation(
      rule: "runtime_atom_creation",
      message: "String.to_atom/1 creates atoms from runtime strings — use tuples or string keys",
      category: "atoms",
      severity: "error",
      file: file,
      line: meta[:line] || 0,
      module: module_name,
      convention_ref: "Atoms > Never create atoms from runtime strings"
    )]
  end

  defp check_string_to_atom(_node, _file, _module), do: []

  # Rule: Never use the process dictionary for application state
  defp check_process_dictionary({{:., meta, [{:__aliases__, _, [:Process]}, func]}, _, _}, file, module_name)
       when func in [:put, :get] do
    [violation(
      rule: "process_dictionary",
      message: "Process.#{func}/2 used — pass state explicitly instead",
      category: "otp",
      severity: "warning",
      file: file,
      line: meta[:line] || 0,
      module: module_name,
      convention_ref: "OTP and Processes > Never use the process dictionary for application state"
    )]
  end

  defp check_process_dictionary(_node, _file, _module), do: []

  # Rule: Always use Task.Supervisor for fire-and-forget tasks
  defp check_task_start_unsupervised({{:., meta, [{:__aliases__, _, [:Task]}, :start]}, _, _}, file, module_name) do
    [violation(
      rule: "unsupervised_task",
      message: "Task.start/1 without supervisor — use Task.Supervisor.start_child/2",
      category: "otp",
      severity: "warning",
      file: file,
      line: meta[:line] || 0,
      module: module_name,
      convention_ref: "OTP and Processes > Always use Task.Supervisor for fire-and-forget tasks"
    )]
  end

  defp check_task_start_unsupervised(_node, _file, _module), do: []

  # Rule: Never use unless...else
  defp check_unless_else({:unless, meta, [_condition, [do: _do_block, else: _else_block]]}, file, module_name) do
    [violation(
      rule: "unless_else",
      message: "unless...else is hard to reason about — use if...else with inverted condition",
      category: "control_flow",
      severity: "warning",
      file: file,
      line: meta[:line] || 0,
      module: module_name,
      convention_ref: "Control Flow > Never use unless...else"
    )]
  end

  defp check_unless_else(_node, _file, _module), do: []

  # Rule: Only pipe when there is an actual transformation chain
  # Uses a two-phase pass to avoid false positives from prewalk (which can't see parent nodes).
  # A pipe chain like `a |> b |> c` nests as `(a |> b) |> c` (left-associative).
  # The inner |> has non-pipe left AND right, so a naive check wrongly flags it.
  # Phase 1: collect meta of all |> nodes that are the LEFT child of another |>.
  # Phase 2: flag |> nodes with non-pipe left that are NOT in the chain-member set.
  defp check_single_value_pipes(ast, file, module_name) do
    # Phase 1: identify chain members (inner |> nodes nested as left child of outer |>)
    {_ast, chain_member_metas} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:|>, _meta, [{:|>, inner_meta, _inner_args}, _right]} = node, acc ->
          {node, MapSet.put(acc, inner_meta)}

        node, acc ->
          {node, acc}
      end)

    # Phase 2: flag standalone single pipes (non-pipe left, not a chain member)
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:|>, _meta, [{:|>, _, _}, _right]} = node, acc ->
          # Left is a pipe — this is a chain continuation, never flag
          {node, acc}

        {:|>, meta, [_left, _right]} = node, acc ->
          if MapSet.member?(chain_member_metas, meta) do
            # This |> is the inner part of a chain — don't flag
            {node, acc}
          else
            v = violation(
              rule: "single_value_pipe",
              message: "Single-value pipe adds noise — call the function directly",
              category: "pipes",
              severity: "info",
              file: file,
              line: meta[:line] || 0,
              module: module_name,
              convention_ref: "Pipes > Only pipe when there is an actual transformation chain"
            )
            {node, [v | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    violations
  end

  # Rule: Never append with ++ in loops (inside Enum.reduce)
  defp check_append_in_reduce(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [_enumerable, _acc, {:fn, _, [{:->, _, [_args, body]}]}]},
         file,
         module_name
       ) do
    if ast_contains_append?(body) do
      [violation(
        rule: "append_in_reduce",
        message: "++ inside Enum.reduce is O(n²) — prepend with [item | acc] and reverse",
        category: "lists",
        severity: "warning",
        file: file,
        line: meta[:line] || 0,
        module: module_name,
        convention_ref: "Lists and Enumerables > Never append with ++ in loops"
      )]
    else
      []
    end
  end

  defp check_append_in_reduce(_node, _file, _module), do: []

  # Rule: Prefer unless over if not
  defp check_if_not({:if, meta, [{:not, _, _} | _]}, file, module_name) do
    [violation(
      rule: "if_not",
      message: "if not ... — use unless for single-branch negation",
      category: "control_flow",
      severity: "info",
      file: file,
      line: meta[:line] || 0,
      module: module_name,
      convention_ref: "Control Flow > Prefer unless over if not for single-branch negation"
    )]
  end

  defp check_if_not(_node, _file, _module), do: []

  # ============================================================================
  # Helpers
  # ============================================================================

  # Suppress violations matching {rule => [module_list]} entries.
  # A violation is suppressed if its rule matches a key AND its module matches any value in that key's list.
  defp apply_suppressions(violations, suppress) when suppress == %{}, do: violations

  defp apply_suppressions(violations, suppress) do
    Enum.reject(violations, fn v ->
      case Map.get(suppress, v.rule) do
        nil -> false
        modules when is_list(modules) -> v.module in modules
        _other -> false
      end
    end)
  end

  defp violation(fields) do
    %{
      rule: Keyword.fetch!(fields, :rule),
      message: Keyword.fetch!(fields, :message),
      category: Keyword.fetch!(fields, :category),
      severity: Keyword.fetch!(fields, :severity),
      file: Keyword.fetch!(fields, :file),
      line: Keyword.fetch!(fields, :line),
      module: Keyword.fetch!(fields, :module),
      convention_ref: Keyword.fetch!(fields, :convention_ref)
    }
  end

  defp first_module_name([]), do: "Unknown"
  defp first_module_name([%{name: name} | _]), do: name

  defp sort_groups(groups) do
    groups
    |> Enum.sort_by(fn {_cat, vs} -> -length(vs) end)
    |> Map.new()
  end

  defp resolve_file_path(file, _project_path), do: file

  defp get_in_keyword(keyword, key) when is_list(keyword) do
    case Keyword.fetch(keyword, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp get_in_keyword(_not_keyword, _key), do: nil

  defp ast_contains_append?({:++, _, [_left, [_single]]}) do
    true
  end

  defp ast_contains_append?({_op, _meta, args}) when is_list(args) do
    Enum.any?(args, &ast_contains_append?/1)
  end

  defp ast_contains_append?(_), do: false

  defp rules_checked do
    [
      %{rule: "missing_moduledoc", category: "documentation", severity: "warning", tier: 1},
      %{rule: "missing_spec", category: "documentation", severity: "warning", tier: 1},
      %{rule: "missing_enforce_keys", category: "structs", severity: "info", tier: 1},
      %{rule: "try_rescue_flow_control", category: "error_handling", severity: "error", tier: 2},
      %{rule: "silent_rescue", category: "error_handling", severity: "error", tier: 2},
      %{rule: "runtime_atom_creation", category: "atoms", severity: "error", tier: 2},
      %{rule: "process_dictionary", category: "otp", severity: "warning", tier: 2},
      %{rule: "unsupervised_task", category: "otp", severity: "warning", tier: 2},
      %{rule: "unless_else", category: "control_flow", severity: "warning", tier: 2},
      %{rule: "single_value_pipe", category: "pipes", severity: "info", tier: 2},
      %{rule: "append_in_reduce", category: "lists", severity: "warning", tier: 2},
      %{rule: "if_not", category: "control_flow", severity: "info", tier: 2}
    ]
  end
end
