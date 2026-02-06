defmodule Giulia.Utils.Diff do
  @moduledoc """
  Simple line-by-line diff utility using Elixir's built-in List.myers_difference.

  Provides unified diff output and ANSI-colored diffs for terminal display.
  Used by the consent gate to show users what changes are being proposed.
  """

  @default_context_lines 3
  @max_diff_lines 50

  @doc """
  Generate a unified diff between old and new content.

  Options:
  - context: number of context lines (default: 3)
  - max_lines: maximum lines to show (default: 50)
  - file_path: optional file path for header

  Returns a list of diff lines with prefixes:
  - " " for context
  - "-" for removed
  - "+" for added
  """
  def unified(old_content, new_content, opts \\ []) do
    context = Keyword.get(opts, :context, @default_context_lines)
    max_lines = Keyword.get(opts, :max_lines, @max_diff_lines)
    file_path = Keyword.get(opts, :file_path)

    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    diff = List.myers_difference(old_lines, new_lines)

    diff_lines = build_unified_diff(diff, context)

    # Add header if file path provided
    header = if file_path do
      ["--- a/#{file_path}", "+++ b/#{file_path}"]
    else
      []
    end

    # Truncate if needed
    {lines, truncated} = truncate_lines(header ++ diff_lines, max_lines)

    if truncated > 0 do
      lines ++ ["... (#{truncated} more lines)"]
    else
      lines
    end
  end

  @doc """
  Generate an ANSI-colored diff for terminal display.

  Options same as unified/3.
  Returns a string with ANSI color codes.
  """
  def colorized(old_content, new_content, opts \\ []) do
    diff_lines = unified(old_content, new_content, opts)

    diff_lines
    |> Enum.map(&colorize_line/1)
    |> Enum.join("\n")
  end

  @doc """
  Preview a new file creation (no diff, just show content).

  Options:
  - max_lines: maximum lines to show (default: 50)
  - file_path: file path for header
  """
  def preview_new(content, opts \\ []) do
    max_lines = Keyword.get(opts, :max_lines, @max_diff_lines)
    file_path = Keyword.get(opts, :file_path, "new file")

    lines = String.split(content, "\n")

    header = ["\e[32m+++ #{file_path} (new file)\e[0m", ""]

    preview_lines = lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} ->
      "\e[32m+ #{String.pad_leading(Integer.to_string(num), 3)}│\e[0m #{line}"
    end)

    {preview_lines, truncated} = truncate_lines(preview_lines, max_lines)

    content = if truncated > 0 do
      preview_lines ++ ["\e[90m... (#{truncated} more lines)\e[0m"]
    else
      preview_lines
    end

    Enum.join(header ++ content, "\n")
  end

  # Build unified diff with context
  defp build_unified_diff(diff, context) do
    # Convert myers_difference to indexed operations with both old and new line numbers
    {ops, _old_num, _new_num} = Enum.reduce(diff, {[], 1, 1}, fn
      {:eq, lines}, {acc, o, n} ->
        new_ops = lines
        |> Enum.with_index()
        |> Enum.map(fn {line, i} -> {:eq, o + i, n + i, line} end)
        {acc ++ new_ops, o + length(lines), n + length(lines)}

      {:del, lines}, {acc, o, n} ->
        new_ops = lines
        |> Enum.with_index()
        |> Enum.map(fn {line, i} -> {:del, o + i, nil, line} end)
        {acc ++ new_ops, o + length(lines), n}

      {:ins, lines}, {acc, o, n} ->
        new_ops = lines
        |> Enum.with_index()
        |> Enum.map(fn {line, i} -> {:ins, nil, n + i, line} end)
        {acc ++ new_ops, o, n + length(lines)}
    end)

    # Filter to show changes with context and group into hunks
    build_hunks(ops, context)
  end

  # Build hunks with context lines and hunk headers
  defp build_hunks(ops, context) do
    # Find indices of all changes
    change_indices = ops
    |> Enum.with_index()
    |> Enum.filter(fn {{op, _, _, _}, _idx} -> op in [:del, :ins] end)
    |> Enum.map(fn {_, idx} -> idx end)

    if change_indices == [] do
      []
    else
      # Expand to include context
      indices_to_show = change_indices
      |> Enum.flat_map(fn idx ->
        Range.new(max(0, idx - context), min(length(ops) - 1, idx + context))
        |> Enum.to_list()
      end)
      |> Enum.uniq()
      |> Enum.sort()

      # Group into continuous ranges (hunks)
      hunks = group_into_hunks(indices_to_show)

      # Build output with hunk headers
      hunks
      |> Enum.flat_map(fn hunk_indices ->
        build_hunk(ops, hunk_indices)
      end)
    end
  end

  # Group indices into continuous hunks (separated by gaps > 1)
  defp group_into_hunks([]), do: []
  defp group_into_hunks([first | rest]) do
    {current_hunk, hunks} = Enum.reduce(rest, {[first], []}, fn idx, {current, acc} ->
      last = List.last(current)
      if idx - last <= 1 do
        {current ++ [idx], acc}
      else
        {[idx], acc ++ [current]}
      end
    end)
    hunks ++ [current_hunk]
  end

  # Build a single hunk with header
  defp build_hunk(ops, indices) do
    hunk_ops = indices |> Enum.map(fn idx -> Enum.at(ops, idx) end)

    # Calculate hunk header
    {old_start, old_count, new_start, new_count} = calculate_hunk_range(hunk_ops)

    header = "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@"

    lines = hunk_ops
    |> Enum.map(fn {op, old_line, new_line, content} ->
      line_prefix = case op do
        :eq -> " "
        :del -> "-"
        :ins -> "+"
      end

      # Show line number hint for context (helps locate in file)
      line_hint = case {op, old_line} do
        {:eq, n} when n != nil -> "#{String.pad_leading(Integer.to_string(n), 4)}│"
        {:del, n} when n != nil -> "#{String.pad_leading(Integer.to_string(n), 4)}│"
        {:ins, _} ->
          case new_line do
            nil -> "    │"
            n -> "#{String.pad_leading(Integer.to_string(n), 4)}│"
          end
        _ -> "    │"
      end

      "#{line_prefix}#{line_hint} #{content}"
    end)

    [header | lines]
  end

  defp calculate_hunk_range(ops) do
    old_lines = ops |> Enum.filter(fn {op, _, _, _} -> op in [:eq, :del] end)
    new_lines = ops |> Enum.filter(fn {op, _, _, _} -> op in [:eq, :ins] end)

    old_start = case old_lines do
      [{_, n, _, _} | _] when n != nil -> n
      _ -> 1
    end

    new_start = case new_lines do
      [{_, _, n, _} | _] when n != nil -> n
      _ -> 1
    end

    old_count = length(old_lines)
    new_count = length(new_lines)

    {old_start, old_count, new_start, new_count}
  end

  defp colorize_line(line) do
    cond do
      String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
        "\e[1m#{line}\e[0m"  # Bold for headers

      String.starts_with?(line, "@@") ->
        "\e[36m#{line}\e[0m"  # Cyan for hunk headers

      String.starts_with?(line, "-") ->
        # Red for deletions, dim line numbers
        case String.split(line, "│", parts: 2) do
          [prefix, content] -> "\e[31m#{prefix}│\e[0m\e[31m#{content}\e[0m"
          _ -> "\e[31m#{line}\e[0m"
        end

      String.starts_with?(line, "+") ->
        # Green for additions, dim line numbers
        case String.split(line, "│", parts: 2) do
          [prefix, content] -> "\e[32m#{prefix}│\e[0m\e[32m#{content}\e[0m"
          _ -> "\e[32m#{line}\e[0m"
        end

      String.starts_with?(line, " ") ->
        # Dim context lines (line numbers normal, content gray)
        case String.split(line, "│", parts: 2) do
          [prefix, content] -> "\e[90m#{prefix}│\e[0m#{content}"
          _ -> "\e[90m#{line}\e[0m"
        end

      String.starts_with?(line, "...") ->
        "\e[90m#{line}\e[0m"  # Gray for truncation

      true ->
        line
    end
  end

  defp truncate_lines(lines, max) when length(lines) <= max, do: {lines, 0}
  defp truncate_lines(lines, max) do
    {Enum.take(lines, max), length(lines) - max}
  end
end
