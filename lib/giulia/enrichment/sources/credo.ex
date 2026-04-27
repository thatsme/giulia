defmodule Giulia.Enrichment.Sources.Credo do
  @moduledoc """
  Parses `mix credo --format json` output into normalized
  `Giulia.Enrichment.Source.finding/0` entries.

  Pre-flight against Plausible (466 files, 3867 functions): 98 issues
  in 39KB JSON, ~10% module-only scopes, 100% field coverage. Parser
  shape and severity mapping are validated against that data.
  """

  @behaviour Giulia.Enrichment.Source

  alias Giulia.Context.Store.Query

  # ============================================================================
  # Severity mapping
  # ============================================================================
  #
  # Credo's "warning" category is misleadingly named — these are bugs,
  # not cautions. Examples: IEx.pry/0 left in code, String.to_atom/1
  # on user input, RaiseInsideRescue. Map to :error.
  @category_to_severity %{
    "warning" => :error,
    "design" => :warning,
    "refactor" => :warning,
    "readability" => :info,
    "consistency" => :info
  }

  @impl true
  def tool_name, do: :credo

  @impl true
  def target_granularity, do: :function

  @impl true
  def parse(payload_path, project_path)
      when is_binary(payload_path) and is_binary(project_path) do
    with {:ok, content} <- File.read(payload_path),
         {:ok, %{"issues" => issues}} when is_list(issues) <- Jason.decode(content) do
      function_index = build_function_index(project_path)
      {:ok, Enum.map(issues, &issue_to_finding(&1, function_index))}
    else
      {:error, reason} -> {:error, {:read_or_decode_failed, reason}}
      {:ok, other} -> {:error, {:unexpected_shape, other}}
    end
  end

  # ============================================================================
  # Function-level line-range index
  # ============================================================================
  #
  # `Query.list_functions/2` returns each function's start `:line` but no
  # end line. We approximate end-line per file as
  # `next_function_in_file.line - 1` after a stable per-file sort by
  # start line. The last function in a file extends to `:infinity`.
  #
  # Returned shape: %{file_path => [%{module, function, arity, line_start, line_end}, ...]}
  # The list per file is sorted by line_start ascending so range lookup
  # can short-circuit.

  @typep range_entry :: %{
           module: String.t(),
           function: String.t(),
           arity: non_neg_integer(),
           line_start: non_neg_integer(),
           line_end: non_neg_integer() | :infinity
         }

  @spec build_function_index(String.t()) :: %{optional(String.t()) => [range_entry()]}
  defp build_function_index(project_path) do
    Query.list_functions(project_path, nil)
    |> Enum.group_by(& &1.file)
    |> Enum.into(%{}, fn {file, funcs} ->
      sorted = Enum.sort_by(funcs, & &1.line)
      ranged = with_end_lines(sorted)
      {file, ranged}
    end)
  end

  defp with_end_lines([]), do: []

  defp with_end_lines(sorted_funcs) do
    pairs = Enum.zip(sorted_funcs, tl(sorted_funcs) ++ [nil])

    Enum.map(pairs, fn
      {func, nil} ->
        %{
          module: func.module,
          function: to_string(func.name),
          arity: func.arity,
          line_start: func.line,
          line_end: :infinity
        }

      {func, next} ->
        %{
          module: func.module,
          function: to_string(func.name),
          arity: func.arity,
          line_start: func.line,
          line_end: max(func.line, next.line - 1)
        }
    end)
  end

  # ============================================================================
  # Per-issue mapping
  # ============================================================================

  defp issue_to_finding(issue, function_index) do
    severity = severity_for(issue["category"])
    base = base_finding(issue, severity)

    case parse_scope(issue["scope"]) do
      {:function_scope, module, function} ->
        resolve_function(base, module, function, issue, function_index)

      {:module_scope, module} ->
        Map.merge(base, %{scope: :module, module: module})

      :unparseable ->
        # Fallback: at minimum keep the file/line; module derived from
        # filename heuristic. Worst case we attach to an unknown module
        # vertex and the consumer can still see the message.
        Map.merge(base, %{scope: :module, module: module_from_filename(issue["filename"])})
    end
  end

  defp base_finding(issue, severity) do
    %{
      severity: severity,
      check: issue["check"] || "",
      message: issue["message"] || "",
      line: issue["line_no"],
      column: issue["column"],
      column_end: issue["column_end"]
    }
    |> drop_nil_keys([:line, :column, :column_end])
  end

  defp severity_for(category) when is_binary(category) do
    Map.get(@category_to_severity, category, :info)
  end

  defp severity_for(_), do: :info

  # ============================================================================
  # Scope parsing
  # ============================================================================
  #
  # Credo's scope is "Module.Submodule.function_name" (function form) or
  # "Module.Submodule" (module form). The function form's last segment
  # starts with a lowercase letter (or _); module segments capitalize.

  defp parse_scope(nil), do: :unparseable
  defp parse_scope(""), do: :unparseable

  defp parse_scope(scope) when is_binary(scope) do
    parts = String.split(scope, ".")

    case List.last(parts) do
      nil ->
        :unparseable

      last ->
        if function_segment?(last) do
          {:function_scope, parts |> Enum.drop(-1) |> Enum.join("."), last}
        else
          {:module_scope, scope}
        end
    end
  end

  defp parse_scope(_), do: :unparseable

  defp function_segment?(segment) do
    case String.first(segment) do
      nil -> false
      ch -> ch == String.downcase(ch) or ch == "_"
    end
  end

  # ============================================================================
  # Three-path arity resolution
  # ============================================================================
  #
  # 1. Line-range resolution against function_index.
  #    - Exactly one match: attach to that {module, fn, arity}.
  #    - Multiple matches, all same name: multi-arity attach (one
  #      finding per arity; finding genuinely applies to all clauses).
  #    - Multiple matches, different names: ambiguous; fall to
  #      module-only with :resolution_ambiguous flag.
  # 2. All-arities fallback: line resolution found nothing but scope
  #    parses to Module.Function — attach to every arity of that name
  #    in that module (or module-only if no such function exists).
  # 3. Module-only: scope had no function segment OR fallback found no
  #    matching function in any arity.

  defp resolve_function(base, module, function, issue, function_index) do
    file = issue["filename"]
    line = issue["line_no"]

    candidates = candidates_for_line(function_index, file, line)

    case candidates do
      [single] ->
        Map.merge(base, %{
          scope: :function,
          module: single.module,
          function: single.function,
          arity: single.arity
        })

      [_ | _] = many ->
        names = many |> Enum.map(& &1.function) |> Enum.uniq()

        if length(names) == 1 do
          # Multi-arity attach: emit finding for the first arity
          # encountered. Writer.replace_for/3 treats one logical
          # finding per (module, fn, arity), so we represent the
          # multi-arity case by returning one finding for the first
          # match. The remaining arities are reachable via
          # Reader.fetch_for_module/2 since the module also receives
          # the finding implicitly through downstream consumer queries
          # if needed. For the v1 slice we keep a single attach point
          # per finding to avoid duplicating the same message N times
          # in pre_impact_check responses; multi-arity expansion is a
          # follow-up if real usage shows we're losing signal.
          first = hd(many)

          Map.merge(base, %{
            scope: :function,
            module: first.module,
            function: first.function,
            arity: first.arity
          })
        else
          # Ambiguous: different function names overlap this line
          # (macro-generated or nested defmacro/defguard). Module
          # attach + flag.
          Map.merge(base, %{
            scope: :module,
            module: module,
            resolution_ambiguous: true
          })
        end

      [] ->
        all_arities_or_module(base, module, function, function_index, file)
    end
  end

  defp all_arities_or_module(base, module, function, function_index, file) do
    fns_in_file = Map.get(function_index, file, [])

    matching =
      Enum.filter(fns_in_file, fn entry ->
        entry.module == module and entry.function == function
      end)

    case matching do
      [first | _] ->
        # Take the first matching arity. Same v1-simplicity rationale
        # as the multi-arity case above.
        Map.merge(base, %{
          scope: :function,
          module: first.module,
          function: first.function,
          arity: first.arity
        })

      [] ->
        Map.merge(base, %{scope: :module, module: module})
    end
  end

  defp candidates_for_line(_function_index, nil, _line), do: []
  defp candidates_for_line(_function_index, _file, nil), do: []

  defp candidates_for_line(function_index, file, line) do
    fns_in_file = Map.get(function_index, file, [])

    Enum.filter(fns_in_file, fn entry ->
      entry.line_start <= line and
        (entry.line_end == :infinity or line <= entry.line_end)
    end)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp module_from_filename(nil), do: "Unknown"

  defp module_from_filename(path) do
    path
    |> Path.basename(".ex")
    |> Path.basename(".exs")
    |> Macro.camelize()
  end

  defp drop_nil_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.get(acc, key) do
        nil -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end
end
