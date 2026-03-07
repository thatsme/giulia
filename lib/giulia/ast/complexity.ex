defmodule Giulia.AST.Complexity do
  @moduledoc """
  Per-function cognitive complexity (Sonar-style).

  Unlike cyclomatic complexity which just counts branches, cognitive complexity
  penalizes **nesting depth** — a nested `if` inside a `case` inside a `with`
  costs more than three flat `if` statements.

  Scoring rules:
  - **Base increment (+1)**: `if`, `unless`, `case`, `cond`, `with`, `for`,
    `try`, `receive`, `and`, `or`, `&&`, `||`
  - **Nesting penalty (+depth)**: Added on top of the base +1 for structural
    nodes (not boolean operators)
  - **Nesting increases on**: `if`, `unless`, `case`, `cond`, `with`, `for`,
    `try`, `receive` — children see depth+1
  - **`cond` clause bonus**: Each clause in `cond` gets +1 beyond the first,
    because each is an independent boolean condition (like chained if/elsif).
    `case`/`receive` clauses do NOT increment — pattern matching is structural.
  - **`fn` resets depth to 0**: Anonymous functions are a new scope. The `fn`
    itself costs +1 (structural break) but the lambda body starts at depth 0.
  - **`with`/`try` blocks**: `do`, `else`, `rescue`, `catch`, `after` are
    siblings — all score at depth+1, none nest inside each other.
  - **No increment**: `else`, `rescue`, `catch`, `after` keywords themselves
    don't add to score.

  Example:
      def simple(x), do: x + 1           # complexity: 0
      def flat(x) do
        if x > 0, do: :pos, else: :neg   # +1 (if at depth 0) = 1
      end
      def nested(x) do
        case x do                         # +1 (case at depth 0)
          :a ->
            if true, do: 1               # +1 + 1 (if at depth 1)
          :b -> :ok
        end                              # total: 3
      end
  """

  # Structural nodes that increase nesting depth for children
  @nesting_nodes [:if, :unless, :case, :cond, :with, :for, :try, :receive]

  # Boolean operators: +1 base, NO nesting penalty, NO depth increase
  @boolean_ops [:and, :or, :&&, :||]

  @doc """
  Compute cognitive complexity for a function body AST.

  Pass the body of a `def`/`defp` (the expressions inside the do-block),
  not the def wrapper itself. Function signature pattern matching is
  structural, not control flow.
  """
  @spec cognitive_complexity(Macro.t()) :: non_neg_integer()
  def cognitive_complexity(ast) do
    try do
      walk(ast, 0, 0)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  @doc """
  Compute cognitive complexity for every function in a file AST.

  Returns a map keyed by `{name, arity}` for easy merging with function_info entries.
  """
  @spec compute_all(Macro.t()) :: %{{atom(), non_neg_integer()} => non_neg_integer()}
  def compute_all(ast) do
    try do
      {_ast, results} = Macro.prewalk(ast, %{}, fn node, acc ->
        case extract_function_body(node) do
          {:ok, name, arity, body_ast} ->
            score = cognitive_complexity(body_ast)
            key = {name, arity}
            # Keep first occurrence (defdelegate + def for same name/arity)
            acc = Map.put_new(acc, key, score)
            {node, acc}

          :skip ->
            {node, acc}
        end
      end)

      results
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  # ============================================================================
  # Function body extraction — find def/defp, return just the do-block body
  # ============================================================================

  @def_types [:def, :defp, :defmacro, :defmacrop]

  # def foo(x) when guard do ... end
  defp extract_function_body({def_type, _meta, [{:when, _, [{name, _, args} | _]} | body]})
       when def_type in @def_types and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, name, arity, extract_do_body(body)}
  end

  # def foo(x) do ... end
  defp extract_function_body({def_type, _meta, [{name, _, args} | body]})
       when def_type in @def_types and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, name, arity, extract_do_body(body)}
  end

  defp extract_function_body(_), do: :skip

  # Standard: [[do: body]]
  defp extract_do_body([[do: body]]), do: body
  # Sourceror format: [[{do_key_ast, body_ast}]]
  defp extract_do_body([[{_do_key, body} | _]]), do: body
  # Inline: [do: body]
  defp extract_do_body([do: body]), do: body
  # Fallback
  defp extract_do_body(other), do: other

  # ============================================================================
  # Recursive AST walker — depth tracked via call stack, not accumulator
  # ============================================================================

  # cond: +1 base + depth penalty, PLUS +1 per clause beyond the first
  defp walk({:cond, _meta, args}, score, depth) when is_list(args) do
    increment = 1 + depth
    clause_bonus = count_cond_clauses(args)
    child_score = walk_block_args(args, 0, depth + 1)
    score + increment + clause_bonus + child_score
  end

  # with: +1 base + depth penalty, do/else blocks are siblings at depth+1
  defp walk({:with, _meta, args}, score, depth) when is_list(args) do
    increment = 1 + depth
    # Walk generator expressions (before the keyword block) at depth+1
    {generators, blocks} = split_with_args(args)
    gen_score = walk_list(generators, 0, depth + 1)
    # Walk do/else blocks as siblings at depth+1
    block_score = walk_sibling_blocks(blocks, 0, depth + 1)
    score + increment + gen_score + block_score
  end

  # try: +1 base + depth penalty, do/rescue/catch/after are siblings at depth+1
  defp walk({:try, _meta, args}, score, depth) when is_list(args) do
    increment = 1 + depth
    child_score = walk_sibling_blocks(args, 0, depth + 1)
    score + increment + child_score
  end

  # Other structural nesting nodes: +1 base + depth penalty, children at depth+1
  defp walk({node_type, _meta, args}, score, depth)
       when node_type in @nesting_nodes and is_list(args) do
    increment = 1 + depth
    child_score = walk_list(args, 0, depth + 1)
    score + increment + child_score
  end

  # Boolean operators: +1 base, NO depth penalty, NO depth increase
  defp walk({op, _meta, [left, right]}, score, depth)
       when op in @boolean_ops do
    left_score = walk(left, 0, depth)
    right_score = walk(right, 0, depth)
    score + 1 + left_score + right_score
  end

  # Anonymous functions (fn -> end): +1 structural break, reset depth to 0
  # Lambda is a new function scope — parent's nesting doesn't carry over
  defp walk({:fn, _meta, clauses}, score, _depth) when is_list(clauses) do
    child_score = walk_list(clauses, 0, 0)
    score + 1 + child_score
  end

  # Generic 3-tuple AST nodes — walk children, no increment, same depth
  defp walk({_node, _meta, args}, score, depth) when is_list(args) do
    child_score = walk_list(args, 0, depth)
    score + child_score
  end

  # Lists (includes keyword lists, clause lists, block children)
  defp walk(list, score, depth) when is_list(list) do
    child_score = walk_list(list, 0, depth)
    score + child_score
  end

  # 2-tuples: keyword pairs like do:/else:/rescue:/catch:/after:
  # These don't add to score — just pass through to children
  defp walk({key, value}, score, depth) when is_atom(key) do
    child_score = walk(value, 0, depth)
    score + child_score
  end

  # Leaf nodes (atoms, numbers, strings, binaries)
  defp walk(_leaf, score, _depth), do: score

  defp walk_list(items, score, depth) do
    Enum.reduce(items, score, fn item, acc ->
      walk(item, acc, depth)
    end)
  end

  # ============================================================================
  # Block helpers — for try/with where sub-blocks are siblings, not nested
  # ============================================================================

  # Walk keyword blocks (do/else/rescue/catch/after) as siblings at the same depth
  defp walk_sibling_blocks(args, score, depth) do
    Enum.reduce(args, score, fn
      # Keyword list: [{:do, body}, {:else, body}, ...]
      kw_list, acc when is_list(kw_list) ->
        Enum.reduce(kw_list, acc, fn
          {_key, body}, inner_acc -> walk(body, inner_acc, depth)
        end)

      # Single keyword pair
      {_key, body}, acc ->
        walk(body, acc, depth)

      # Regular arg (generator in with, etc.)
      other, acc ->
        walk(other, acc, depth)
    end)
  end

  # Walk block args but skip through keyword wrappers to body
  defp walk_block_args(args, score, depth) do
    Enum.reduce(args, score, fn
      kw_list, acc when is_list(kw_list) ->
        Enum.reduce(kw_list, acc, fn
          {_key, body}, inner_acc -> walk(body, inner_acc, depth)
        end)

      {_key, body}, acc ->
        walk(body, acc, depth)

      other, acc ->
        walk(other, acc, depth)
    end)
  end

  # ============================================================================
  # Clause & arg helpers
  # ============================================================================

  # Count cond clauses beyond the first: each independent boolean condition gets +1
  defp count_cond_clauses(args) do
    clause_count = extract_cond_clause_count(args)
    max(clause_count - 1, 0)
  end

  defp extract_cond_clause_count([]), do: 0

  defp extract_cond_clause_count([head | tail]) do
    case head do
      [{_do_key, clauses}] when is_list(clauses) -> length(clauses)
      [{_do_key, clauses} | _] when is_list(clauses) -> length(clauses)
      {:do, clauses} when is_list(clauses) -> length(clauses)
      [do: clauses] when is_list(clauses) -> length(clauses)
      _ -> extract_cond_clause_count(tail)
    end
  end

  # Split with args into generators and keyword blocks
  defp split_with_args(args) do
    Enum.split_while(args, fn
      kw when is_list(kw) -> not Keyword.keyword?(kw)
      {key, _} when key in [:do, :else] -> false
      _ -> true
    end)
  end
end
