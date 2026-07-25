defmodule Giulia.Knowledge.Otp do
  @moduledoc """
  OTP deep-analysis checks — process architecture, not module structure.

  Credo checks syntax-level style and Dialyzer checks types; neither looks at
  how processes are started or how they talk to each other. These checks target
  bug classes that appear in production and not in tests, because they are
  load- and interleaving-dependent.

  Phase 2 ships the two pure-AST checks:

    * `blocking_init/2` — blocking calls inside `init/1`, which run inside the
      supervisor's start sequence
    * `missing_catch_all_handle_info/1` — a GenServer that defines `handle_info/2`
      clauses but no catch-all, having thereby overridden the injected default

  Findings mirror the `Knowledge.Conventions` shape (`rule`, `message`,
  `category`, `severity`, `file`, `line`, `module`) so report tooling and the
  MCP layer inherit it for free.

  All thresholds and MFA lists come from `Giulia.Config.OtpChecks`
  (`priv/config/otp_checks.json`) — nothing about which calls count as blocking
  is compiled in.
  """

  alias Giulia.Config.OtpChecks

  @behaviour_aliases ["GenServer", "Supervisor"]

  @type finding :: %{
          rule: String.t(),
          message: String.t(),
          category: String.t(),
          severity: String.t(),
          file: String.t(),
          line: non_neg_integer(),
          module: String.t()
        }

  # ============================================================================
  # Entry point
  # ============================================================================

  @doc """
  Run every OTP check over a project, in the conventions response shape.

  `opts` accepts `:suppress` (a `%{rule => [module]}` map, as parsed by
  `Daemon.Helpers.parse_suppress/1`) and `:check` to filter to a single rule.
  """
  @spec otp_risks(String.t(), keyword()) :: {:ok, map()}
  def otp_risks(project_path, opts \\ []) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    suppress = Keyword.get(opts, :suppress, %{})
    check_filter = Keyword.get(opts, :check)

    modules = parse_modules(all_asts)

    findings = blocking_init(modules, opts) ++ missing_catch_all_handle_info(modules)

    findings =
      findings
      |> filter_by_check(check_filter)
      |> apply_suppressions(suppress)
      |> Enum.sort_by(&{&1.file, &1.line})

    by_severity = Enum.frequencies_by(findings, & &1.severity)

    result = %{
      total_findings: length(findings),
      by_severity: %{
        error: Map.get(by_severity, "error", 0),
        warning: Map.get(by_severity, "warning", 0),
        info: Map.get(by_severity, "info", 0)
      },
      by_check: findings |> Enum.group_by(& &1.rule) |> sort_groups(),
      checks_run: checks_run()
    }

    result = if check_filter, do: Map.put(result, :check_filter, check_filter), else: result
    result = if suppress != %{}, do: Map.put(result, :suppressions_applied, suppress), else: result

    {:ok, result}
  end

  @doc """
  Rules this module currently implements. Phase 3 extends the list.
  """
  @spec checks_run() :: [String.t()]
  def checks_run, do: ["blocking_init", "missing_catch_all_handle_info"]

  # ============================================================================
  # blocking_init
  # ============================================================================

  @doc """
  Blocking calls inside `init/1`, plus the intra-module private-helper closure.

  `init/1` runs inside the supervisor's start sequence: a blocking call
  serialises boot, and a dependency that is down turns into a restart-intensity
  cascade that takes the tree with it. The idiomatic fix is to return
  `{:ok, state, {:continue, :load}}` and do the work in `handle_continue/2`.

  Severity is tiered by `otp_checks.json`: network, DB and cross-process calls
  are errors; `File.*` is a warning, because reading config at boot is
  legitimate and the file's size is unknowable statically.

  A module that already defines `handle_continue/2` gets that noted in the
  finding — the author knows the idiom, so a remaining blocking call is more
  likely deliberate.
  """
  @spec blocking_init([map()], keyword()) :: [finding()]
  def blocking_init(modules, _opts \\ []) do
    modules
    |> Enum.filter(&process_module?/1)
    |> Enum.flat_map(&blocking_calls_in_init/1)
  end

  defp blocking_calls_in_init(module) do
    case Map.fetch(module.functions, {"init", 1}) do
      :error ->
        []

      {:ok, clauses} ->
        reachable = reachable_bodies(module, clauses)

        reachable
        |> Enum.flat_map(&qualified_calls/1)
        |> Enum.flat_map(fn {mfa, line} ->
          case OtpChecks.blocking_severity(mfa) do
            nil -> []
            severity -> [blocking_finding(module, mfa, line, severity)]
          end
        end)
        |> Enum.uniq_by(& &1.message)
    end
  end

  # init/1's own bodies plus the transitive closure of same-module private
  # helpers it calls. A blocking call one hop away from init/1 blocks boot
  # exactly as much as one written inline.
  defp reachable_bodies(module, init_clauses) do
    do_reachable(module, Enum.map(init_clauses, & &1.body), MapSet.new([{"init", 1}]))
  end

  defp do_reachable(module, bodies, visited) do
    called =
      bodies
      |> Enum.flat_map(&unqualified_calls/1)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.filter(&Map.has_key?(module.functions, &1))
      |> Enum.uniq()

    case called do
      [] ->
        bodies

      _ ->
        visited = Enum.reduce(called, visited, &MapSet.put(&2, &1))

        next_bodies =
          Enum.flat_map(called, fn key ->
            module.functions |> Map.fetch!(key) |> Enum.map(& &1.body)
          end)

        bodies ++ do_reachable(module, next_bodies, visited)
    end
  end

  defp blocking_finding(module, mfa, line, severity) do
    continue_note =
      if Map.has_key?(module.functions, {"handle_continue", 2}) do
        " (module defines handle_continue/2 — may be deliberate)"
      else
        " — consider {:ok, state, {:continue, :load}} and do this in handle_continue/2"
      end

    %{
      rule: "blocking_init",
      message: "#{mfa} called from init/1 blocks the supervisor start sequence" <> continue_note,
      category: "otp_deep",
      severity: Atom.to_string(severity),
      file: module.file,
      line: line,
      module: module.name
    }
  end

  # ============================================================================
  # missing_catch_all_handle_info
  # ============================================================================

  @doc """
  A GenServer defining `handle_info/2` clauses with no catch-all among them.

  `use GenServer` injects a default `handle_info/2` that logs unexpected
  messages — but defining *any* clause overrides the injected default
  completely. From that moment a late `Task` reply, a `:DOWN` message or port
  noise crashes the server. This is the classic once-a-month-in-production,
  never-in-tests bug.

  Fires only when clauses exist and none is an unguarded catch-all. A module
  defining no `handle_info/2` at all keeps the injected default and is clean —
  flagging it would be a false positive on the majority of GenServers.
  """
  @spec missing_catch_all_handle_info([map()]) :: [finding()]
  def missing_catch_all_handle_info(modules) do
    modules
    |> Enum.filter(&process_module?/1)
    |> Enum.flat_map(fn module ->
      case Map.fetch(module.functions, {"handle_info", 2}) do
        :error ->
          []

        {:ok, clauses} ->
          if Enum.any?(clauses, &catch_all_clause?/1) do
            []
          else
            [
              %{
                rule: "missing_catch_all_handle_info",
                message:
                  "#{module.name} defines #{length(clauses)} handle_info/2 clause(s) but no " <>
                    "catch-all — defining any clause overrides the default `use GenServer` " <>
                    "injects, so an unmatched message now crashes the server",
                category: "otp_deep",
                severity: OtpChecks.missing_catch_all_severity(),
                file: module.file,
                line: clauses |> Enum.map(& &1.line) |> Enum.min(),
                module: module.name
              }
            ]
          end
      end
    end)
  end

  # A catch-all matches any message: first argument is a bare variable (or `_`)
  # and the clause carries no guard. A guarded clause is not a catch-all — the
  # guard is exactly what makes it selective.
  defp catch_all_clause?(%{guarded: true}), do: false

  defp catch_all_clause?(%{args: [{name, _meta, ctx} | _rest]})
       when is_atom(name) and is_atom(ctx),
       do: true

  defp catch_all_clause?(_clause), do: false

  # ============================================================================
  # Shared parsing
  # ============================================================================

  @doc """
  Parse project sources into the module structures the checks consume.

  Exposed so tests can build the structure from a fixture path without going
  through `Context.Store`.
  """
  @spec parse_modules(%{String.t() => map()}) :: [map()]
  def parse_modules(all_asts) do
    all_asts
    |> Map.keys()
    |> Enum.flat_map(&modules_in_file/1)
  end

  defp modules_in_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast
      |> module_nodes()
      |> Enum.map(fn {name, line, body} ->
        %{
          name: name,
          file: path,
          line: line,
          uses: uses_in(body),
          functions: functions_in(body)
        }
      end)
    else
      _ -> []
    end
  end

  defp module_nodes(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [alias_ast, body_kw]} = node, acc when is_list(body_kw) ->
          case {render_alias(alias_ast), Keyword.fetch(body_kw, :do)} do
            {nil, _} -> {node, acc}
            {_name, :error} -> {node, acc}
            {name, {:ok, body}} -> {node, [{name, meta[:line] || 0, body} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `use GenServer` / `@behaviour GenServer` — either marks a process module.
  defp uses_in(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {:use, _meta, [alias_ast | _]} = node, acc ->
          {node, [render_alias(alias_ast) | acc]}

        {:@, _meta, [{:behaviour, _, [alias_ast]}]} = node, acc ->
          {node, [render_alias(alias_ast) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp process_module?(%{uses: uses}), do: Enum.any?(uses, &(&1 in @behaviour_aliases))

  # `%{{name, arity} => [clause]}` — a clause carries its args, body, line and
  # whether it is guarded, which is all the checks need.
  defp functions_in(body) do
    {_ast, clauses} =
      Macro.prewalk(body, [], fn
        {kind, meta, [head, body_kw]} = node, acc
        when kind in [:def, :defp] and is_list(body_kw) ->
          case {parse_head(head), Keyword.fetch(body_kw, :do)} do
            {nil, _} ->
              {node, acc}

            {_, :error} ->
              {node, acc}

            {{name, args, guarded?}, {:ok, fn_body}} ->
              clause = %{
                args: args,
                body: fn_body,
                line: meta[:line] || 0,
                guarded: guarded?
              }

              {node, [{{name, length(args)}, clause} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    clauses
    |> Enum.reverse()
    |> Enum.group_by(fn {key, _} -> key end, fn {_, clause} -> clause end)
  end

  # `def foo(a, b) when guard` wraps the head in `:when`.
  defp parse_head({:when, _meta, [inner_head, _guard]}) do
    case parse_head(inner_head) do
      {name, args, _} -> {name, args, true}
      nil -> nil
    end
  end

  defp parse_head({name, _meta, args}) when is_atom(name) and is_list(args) do
    {Atom.to_string(name), args, false}
  end

  defp parse_head({name, _meta, nil}) when is_atom(name), do: {Atom.to_string(name), [], false}
  defp parse_head(_other), do: nil

  # `Mod.fun(...)` → {"Mod.fun", line}. Erlang modules render with their colon
  # so `:timer.sleep` stays distinguishable from a `Timer.sleep` alias.
  defp qualified_calls(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [mod_ast, fun]}, meta, _args} = node, acc when is_atom(fun) ->
          case render_call_module(mod_ast) do
            nil -> {node, acc}
            mod -> {node, [{"#{mod}.#{fun}", meta[:line] || 0} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Local calls, for the intra-module helper closure.
  defp unqualified_calls(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{Atom.to_string(name), length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  defp render_call_module({:__aliases__, _, _} = alias_ast), do: render_alias(alias_ast)
  defp render_call_module(mod) when is_atom(mod), do: inspect(mod)
  defp render_call_module(_other), do: nil

  defp render_alias({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp render_alias(atom) when is_atom(atom) and not is_nil(atom), do: inspect(atom)
  defp render_alias(_other), do: nil

  # ============================================================================
  # Filtering
  # ============================================================================

  defp filter_by_check(findings, nil), do: findings
  defp filter_by_check(findings, check), do: Enum.filter(findings, &(&1.rule == check))

  defp apply_suppressions(findings, suppress) when suppress == %{}, do: findings

  defp apply_suppressions(findings, suppress) do
    Enum.reject(findings, fn finding ->
      case Map.fetch(suppress, finding.rule) do
        {:ok, modules} -> finding.module in modules
        :error -> false
      end
    end)
  end

  defp sort_groups(groups) do
    groups
    |> Enum.sort_by(fn {_check, findings} -> -length(findings) end)
    |> Map.new()
  end
end
