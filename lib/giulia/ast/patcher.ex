defmodule Giulia.AST.Patcher do
  @moduledoc """
  AST code patching — replace, insert, and locate functions in source code.

  Uses Sourceror directly for AST manipulation. Standalone module with
  no dependencies on other AST sub-modules.
  """

  @doc """
  Patch a specific function in the source code.
  Returns the modified source with formatting preserved.
  """
  @spec patch_function(String.t(), atom(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def patch_function(source, function_name, arity, new_body) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, new_ast} <- Sourceror.parse_string(new_body) do
      {patched, _acc} =
        Macro.postwalk(ast, nil, fn
          # Standard: def foo(args)
          {def_type, _meta, [{^function_name, _fn_meta, args} | _]} = node, acc
          when def_type in [:def, :defp] ->
            if length(args || []) == arity do
              {new_ast, acc}
            else
              {node, acc}
            end

          # With when clause: def foo(args) when guard
          {def_type, _meta, [{:when, _, [{^function_name, _, args} | _]} | _]} = node, acc
          when def_type in [:def, :defp] ->
            if length(args || []) == arity do
              {new_ast, acc}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      {:ok, Macro.to_string(patched)}
    end
  end

  @doc """
  Insert a new function into a module.
  """
  @spec insert_function(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def insert_function(source, module_name, function_source) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, func_ast} <- Sourceror.parse_string(function_source) do
      # Module name parts must be atoms for AST pattern matching (Sourceror).
      # These are bounded by the project's compiled modules.
      module_parts = String.split(module_name, ".") |> Enum.map(&String.to_existing_atom/1)

      {patched, _acc} =
        Macro.postwalk(ast, nil, fn
          {:defmodule, meta, [{:__aliases__, alias_meta, ^module_parts}, body_block]}, acc ->
            case body_block do
              [do: {:__block__, block_meta, body}] ->
                new_body = body ++ [func_ast]

                node =
                  {:defmodule, meta,
                   [
                     {:__aliases__, alias_meta, module_parts},
                     [do: {:__block__, block_meta, new_body}]
                   ]}

                {node, acc}

              [{_do_key, body}] ->
                # Single expression body — wrap in block
                node =
                  {:defmodule, meta,
                   [
                     {:__aliases__, alias_meta, module_parts},
                     [do: {:__block__, [], [body, func_ast]}]
                   ]}

                {node, acc}

              _ ->
                {{:defmodule, meta, [{:__aliases__, alias_meta, module_parts}, body_block]}, acc}
            end

          node, acc ->
            {node, acc}
        end)

      {:ok, Macro.to_string(patched)}
    end
  end

  @doc """
  Get the source range for a specific function.
  """
  @spec get_function_range(Macro.t(), atom(), non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :not_found
  def get_function_range(ast, function_name, arity) do
    {_, result} =
      Macro.prewalk(ast, nil, fn
        # Standard: def foo(args)
        {def_type, meta, [{^function_name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            start_line = Keyword.get(meta, :line, 0)
            end_line = Keyword.get(meta, :end_of_expression, []) |> Keyword.get(:line, start_line)
            {node, {start_line, end_line}}
          else
            {node, nil}
          end

        # With when clause: def foo(args) when guard
        {def_type, meta, [{:when, _, [{^function_name, _, args} | _]} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            start_line = Keyword.get(meta, :line, 0)
            end_line = Keyword.get(meta, :end_of_expression, []) |> Keyword.get(:line, start_line)
            {node, {start_line, end_line}}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    case result do
      nil -> :not_found
      range -> {:ok, range}
    end
  end
end
