defmodule Giulia.AST.Slicer do
  @moduledoc """
  Context slicing for LLM consumption — extract focused code snippets
  from source files.

  Functions, function-with-deps, line-range, and error-context slicing.
  Uses Sourceror directly for AST traversal. No dependency on other AST
  sub-modules.
  """

  @doc """
  Extract only a specific function from source code.
  Returns the function source with minimal context.

  Use this for small models (3B) - 20 lines of context beats 200.
  """
  @spec slice_function(String.t(), atom(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def slice_function(source, function_name, arity) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      {_ast, result} = Macro.prewalk(ast, nil, fn
        # Standard: def foo(args)
        {def_type, _meta, [{name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] and is_atom(name) and name != :when ->
          if matches_function?(name, args, function_name, arity) do
            {node, Macro.to_string(node)}
          else
            {node, nil}
          end

        # With when clause: def foo(args) when guard
        {def_type, _meta, [{:when, _, [{name, _, args} | _]} | _]} = node, nil
        when def_type in [:def, :defp] and is_atom(name) ->
          if matches_function?(name, args, function_name, arity) do
            {node, Macro.to_string(node)}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

      case result do
        nil -> {:error, :function_not_found}
        func_source -> {:ok, func_source}
      end
    end
  end

  defp matches_function?(name, args, target_name, target_arity) do
    name_matches = name == target_name or to_string(name) == to_string(target_name)
    arity_matches = length(args || []) == target_arity
    name_matches and arity_matches
  end

  @doc """
  Extract a function and its direct dependencies (called functions in same module).
  Returns a focused slice of code for the LLM.
  """
  @spec slice_function_with_deps(String.t(), atom(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def slice_function_with_deps(source, function_name, arity) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, target_func} <- find_function_ast(ast, function_name, arity) do
      # Find functions called within the target
      called_functions = extract_called_functions(target_func)

      # Extract all relevant functions
      slices =
        [{function_name, arity} | called_functions]
        |> Enum.uniq()
        |> Enum.map(fn {name, ar} -> find_function_ast(ast, name, ar) end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, func_ast} -> Macro.to_string(func_ast) end)

      {:ok, Enum.join(slices, "\n\n")}
    end
  end

  @doc """
  Slice source to only include lines around an error location.
  Useful for sending error context to small models.
  """
  @spec slice_around_line(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def slice_around_line(source, line, context_lines \\ 10)

  def slice_around_line(source, line, context_lines) when is_binary(source) do
    safe_line = if is_integer(line), do: line, else: 1
    safe_context = if is_integer(context_lines), do: context_lines, else: 10

    lines = String.split(source, "\n")
    total_lines = length(lines)

    start_line = max(0, safe_line - safe_context - 1)
    end_line = min(total_lines - 1, safe_line + safe_context - 1)

    lines
    |> Enum.slice(start_line..end_line)
    |> Enum.with_index(start_line + 1)
    |> Enum.map_join("\n", fn {content, num} ->
      marker = if num == safe_line, do: ">>> ", else: "    "
      "#{marker}#{num}: #{content}"
    end)
  end

  def slice_around_line(_, _, _), do: ""

  @doc """
  Create a minimal context for a specific error.
  Combines function slice with error location.
  """
  @spec slice_for_error(String.t(), non_neg_integer(), String.t()) :: String.t()
  def slice_for_error(source, error_line, error_message) do
    # Parse directly — no facade dependency
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        func = find_function_at_line(ast, error_line)

        case func do
          nil ->
            """
            Error: #{error_message}

            Context:
            #{slice_around_line(source, error_line)}
            """

          {name, arity, func_source} ->
            """
            Error in #{name}/#{arity}: #{error_message}

            Function:
            #{func_source}
            """
        end

      _ ->
        """
        Error: #{error_message}

        Context:
        #{slice_around_line(source, error_line)}
        """
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp find_function_ast(ast, function_name, arity) do
    {_, result} =
      Macro.prewalk(ast, nil, fn
        # Standard: def foo(args)
        {def_type, _meta, [{^function_name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            {node, node}
          else
            {node, nil}
          end

        # With when clause: def foo(args) when guard
        {def_type, _meta, [{:when, _, [{^function_name, _, args} | _]} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            {node, node}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    case result do
      nil -> {:error, :not_found}
      func -> {:ok, func}
    end
  end

  defp find_function_at_line(ast, target_line) do
    {_, result} =
      Macro.prewalk(ast, nil, fn
        # Standard: def foo(args)
        {def_type, meta, [{name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] and is_atom(name) and name != :when ->
          start_line = Keyword.get(meta, :line, 0)
          end_line = get_end_line(meta, start_line)
          arity = length(args || [])

          if target_line >= start_line and target_line <= end_line do
            {node, {name, arity, Macro.to_string(node)}}
          else
            {node, nil}
          end

        # With when clause: def foo(args) when guard
        {def_type, meta, [{:when, _, [{name, _, args} | _]} | _]} = node, nil
        when def_type in [:def, :defp] and is_atom(name) ->
          start_line = Keyword.get(meta, :line, 0)
          end_line = get_end_line(meta, start_line)
          arity = length(args || [])

          if target_line >= start_line and target_line <= end_line do
            {node, {name, arity, Macro.to_string(node)}}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    result
  end

  defp extract_called_functions(func_ast) do
    {_, result} =
      Macro.prewalk(func_ast, [], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          if name in [:def, :defp, :do, :end, :if, :case, :cond, :fn, :&, :|>] do
            {node, acc}
          else
            {node, [{name, length(args)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(result)
  end

  defp get_line_range(meta) when is_list(meta) do
    start_line = Keyword.get(meta, :line, 1)
    end_line = case Keyword.get(meta, :end_of_expression) do
      nil -> start_line
      end_meta when is_list(end_meta) -> Keyword.get(end_meta, :line, start_line)
      _ -> start_line
    end
    {start_line, end_line}
  end

  defp get_line_range(_), do: {1, 1}

  defp get_end_line(meta, default) when is_list(meta) and is_integer(default) do
    {_start, end_line} = get_line_range(meta)
    if end_line > 0, do: end_line, else: default
  end

  defp get_end_line(_, default) when is_integer(default), do: default
  defp get_end_line(_, _), do: 1
end
