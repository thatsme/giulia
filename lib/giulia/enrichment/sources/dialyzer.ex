defmodule Giulia.Enrichment.Sources.Dialyzer do
  @moduledoc """
  Parses `mix dialyzer --format short` output into normalized
  `Giulia.Enrichment.Source.finding/0` entries.

  Format (per dialyxir's `Formatter.Short`):

      {relative_file}:{line}[:{column}]:{warning_name} {message}

  Example:

      lib/foo/bar.ex:42:no_return Function quux/2 has no local return.
      lib/foo/baz.ex:17:5:pattern_match The pattern can never match the type ...

  Severity mapping for the 47 dialyxir warning types lives in
  `priv/config/enrichment_sources.json` under the `dialyzer` source.
  Tunable without recompile.

  Unlike Credo, Dialyzer's short output does not include a
  `Module.function` scope field. Function-level attribution comes
  exclusively from line-range matching against Giulia's per-function
  line index (same path-1 mechanism the Credo parser uses); when the
  line resolves to no function, the parser falls back to a module
  derived from the file path.
  """

  @behaviour Giulia.Enrichment.Source

  alias Giulia.Context.Store.Query
  alias Giulia.Enrichment.Registry

  # path:line[:col]:warning_name message
  @line_regex ~r/^(?<file>[^:]+):(?<line>\d+)(?::(?<col>\d+))?:(?<warning>[a-z_]+)\s+(?<message>.*)$/

  @impl true
  def tool_name, do: :dialyzer

  @impl true
  def target_granularity, do: :function

  @impl true
  def parse(payload_path, project_path)
      when is_binary(payload_path) and is_binary(project_path) do
    with {:ok, content} <- File.read(payload_path) do
      function_index = build_function_index(project_path)

      findings =
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn parsed -> parsed_to_finding(parsed, function_index) end)

      {:ok, findings}
    else
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  # ============================================================================
  # Line parsing
  # ============================================================================

  @typep parsed :: %{
           file: String.t(),
           line: pos_integer(),
           column: non_neg_integer() | nil,
           warning_name: String.t(),
           message: String.t()
         }

  @spec parse_line(String.t()) :: parsed() | nil
  defp parse_line(line) do
    case Regex.named_captures(@line_regex, line) do
      %{"file" => file, "line" => line_str, "warning" => warning, "message" => message} = caps ->
        %{
          file: file,
          line: String.to_integer(line_str),
          column: caps["col"] |> nilable_int(),
          warning_name: warning,
          message: message
        }

      nil ->
        nil
    end
  end

  defp nilable_int(""), do: nil
  defp nilable_int(nil), do: nil
  defp nilable_int(s) when is_binary(s), do: String.to_integer(s)

  # ============================================================================
  # Finding construction
  # ============================================================================

  defp parsed_to_finding(parsed, function_index) do
    severity = Registry.severity_for(:dialyzer, parsed.warning_name)
    base = base_finding(parsed, severity)

    case resolve_function(parsed, function_index) do
      {:ok, module, function, arity} ->
        Map.merge(base, %{
          scope: :function,
          module: module,
          function: function,
          arity: arity
        })

      {:module_only, module} ->
        Map.merge(base, %{scope: :module, module: module})

      {:module_only_ambiguous, module} ->
        Map.merge(base, %{
          scope: :module,
          module: module,
          resolution_ambiguous: true
        })
    end
  end

  defp base_finding(parsed, severity) do
    %{
      severity: severity,
      check: parsed.warning_name,
      message: parsed.message,
      line: parsed.line
    }
    |> maybe_put(:column, parsed.column)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ============================================================================
  # Function-level resolution (line-range index)
  # ============================================================================
  #
  # Dialyzer doesn't provide a Module.Function scope string the way
  # Credo does, so all function-level resolution goes through the line
  # index. Same three sub-cases as the Credo parser:
  #   - exactly one function vertex covers the line → attach
  #   - multiple matches with the same name (clauses) → first match
  #     (multi-arity expansion deferred to a follow-up)
  #   - multiple matches with different names → ambiguous, module-only
  #     attach with :resolution_ambiguous flag
  #
  # When line resolution finds nothing, fall back to a module derived
  # from the file path. The function_index is keyed by absolute file
  # path; Dialyzer outputs paths relative to the project root, so we
  # try both forms.

  defp resolve_function(parsed, function_index) do
    candidates =
      candidates_for_line(function_index, parsed.file, parsed.line) ++
        candidates_for_line(function_index, absolute_for(parsed.file, function_index), parsed.line)

    case Enum.uniq(candidates) do
      [single] ->
        {:ok, single.module, single.function, single.arity}

      [_ | _] = many ->
        names = many |> Enum.map(& &1.function) |> Enum.uniq()

        if length(names) == 1 do
          first = hd(many)
          {:ok, first.module, first.function, first.arity}
        else
          {:module_only_ambiguous, module_from_filename(parsed.file)}
        end

      [] ->
        {:module_only, module_from_filename(parsed.file)}
    end
  end

  defp candidates_for_line(_index, nil, _line), do: []

  defp candidates_for_line(function_index, file, line) do
    fns_in_file = Map.get(function_index, file, [])

    Enum.filter(fns_in_file, fn entry ->
      entry.line_start <= line and
        (entry.line_end == :infinity or line <= entry.line_end)
    end)
  end

  # Try to find an absolute path in the index whose suffix matches the
  # relative path Dialyzer emitted. Returns the first match or nil.
  defp absolute_for(rel_file, function_index) do
    function_index
    |> Map.keys()
    |> Enum.find(fn k -> String.ends_with?(k, "/" <> rel_file) end)
  end

  # ============================================================================
  # Function index — same shape as the Credo parser uses
  # ============================================================================

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

  defp module_from_filename(nil), do: "Unknown"

  defp module_from_filename(path) do
    path
    |> Path.basename(".ex")
    |> Path.basename(".exs")
    |> Macro.camelize()
  end
end
