defmodule Giulia.Context.LineResolver do
  @moduledoc """
  Resolves a source position `{file, line}` to the indexed function — and thus
  the module — that contains it.

  Two subsystems need to map a raw `{file, line}` back to the AST vertex that
  owns that line:

  - the enrichment correlator (`Giulia.Enrichment.Sources.Credo`) — to attach a
    tool finding to the right function/arity, and
  - the conventions analyzer (`Giulia.Knowledge.Conventions`) — to attribute an
    AST-walk violation to the module that actually contains it.

  This module is the single source of that logic so the two consumers cannot
  drift apart.

  The index is built from `Giulia.Context.Store.Query.list_functions/2`, which
  gives each function's start `:line` but no end line. End lines are
  approximated per file as `next_function.line - 1` after a stable per-file sort
  by start line; the last function in a file extends to `:infinity`.

  Each indexed function carries its true enclosing `:module` (the extractor
  assigns it during AST traversal), so resolving a line to its function yields
  the correct module even for files holding multiple or nested modules
  (co-located exceptions, several schemas per file). The next-function-start
  cap also bounds the last function of a module at the line before the next
  module's first function, so the flat multi-module case attributes correctly.

  File keys are whatever `Query.list_functions/2` stores — absolute container
  paths in the running daemon. Callers must look up with the same path form they
  hold; the store and its consumers agree on absolute paths.
  """

  alias Giulia.Context.Store.Query

  @type range_entry :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          line_start: non_neg_integer(),
          line_end: non_neg_integer() | :infinity
        }

  @type index :: %{optional(String.t()) => [range_entry()]}

  @doc """
  Build a per-file function line-range index for `project_path`.

  Shape: `%{file => [range_entry, ...]}`. Each file's list is sorted by
  `line_start` ascending so range lookup can short-circuit.
  """
  @spec build_function_index(String.t()) :: index()
  def build_function_index(project_path) do
    Query.list_functions(project_path, nil)
    |> Enum.group_by(& &1.file)
    |> Enum.into(%{}, fn {file, funcs} ->
      sorted = Enum.sort_by(funcs, & &1.line)
      {file, with_end_lines(sorted)}
    end)
  end

  @doc """
  Return every range entry whose line range contains `line` in `file`.

  Empty list when `file`/`line` is nil, the file is unknown, or no function
  covers the line (e.g. a module-attribute line outside any `def`).
  """
  @spec candidates_for_line(index(), String.t() | nil, non_neg_integer() | nil) :: [range_entry()]
  def candidates_for_line(_index, nil, _line), do: []
  def candidates_for_line(_index, _file, nil), do: []

  def candidates_for_line(index, file, line) do
    index
    |> Map.get(file, [])
    |> Enum.filter(fn entry ->
      entry.line_start <= line and
        (entry.line_end == :infinity or line <= entry.line_end)
    end)
  end

  @doc """
  Resolve `{file, line}` to the containing module name, or `nil` when no
  indexed function covers the line.

  When several functions overlap the line (multi-clause / multi-arity) they
  share a module in the common case; this returns the first candidate's module.
  """
  @spec resolve_module(index(), String.t() | nil, non_neg_integer() | nil) :: String.t() | nil
  def resolve_module(index, file, line) do
    case candidates_for_line(index, file, line) do
      [entry | _] -> entry.module
      [] -> nil
    end
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
end
