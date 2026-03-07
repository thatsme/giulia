defmodule Giulia.AST.ComplexityTest do
  use ExUnit.Case, async: true

  alias Giulia.AST.Complexity

  # ============================================================================
  # Unit tests — cognitive_complexity/1 on raw body AST
  # ============================================================================

  describe "cognitive_complexity/1 basics" do
    test "empty body scores 0" do
      assert Complexity.cognitive_complexity(:ok) == 0
    end

    test "flat if scores 1 (depth 0)" do
      ast = parse_body("if x > 0, do: :pos, else: :neg")
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "flat unless scores 1" do
      ast = parse_body("unless x, do: :nope")
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "sibling ifs at same depth each score 1" do
      ast = parse_body("""
      if a, do: 1
      if b, do: 2
      if c, do: 3
      """)
      assert Complexity.cognitive_complexity(ast) == 3
    end

    test "graceful on invalid input" do
      assert Complexity.cognitive_complexity(nil) == 0
      assert Complexity.cognitive_complexity(42) == 0
      assert Complexity.cognitive_complexity("not ast") == 0
    end
  end

  describe "cognitive_complexity/1 nesting" do
    test "nested if inside case: case(+1) + if(+1+1) = 3" do
      ast = parse_body("""
      case x do
        :a ->
          if true, do: 1
        :b -> :ok
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 3
    end

    test "three levels: if > case > if = 1 + 2 + 3 = 6" do
      ast = parse_body("""
      if x do
        case y do
          :a ->
            if z, do: 1
        end
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 6
    end

    test "10 levels of nesting: sum of (1+0) through (1+9) = 55" do
      inner = "x"
      code = Enum.reduce(1..10, inner, fn _, acc ->
        "if true do\n#{acc}\nend"
      end)

      ast = parse_body(code)
      assert Complexity.cognitive_complexity(ast) == 55
    end
  end

  describe "cognitive_complexity/1 case/cond/receive" do
    test "case with many clauses scores 1 (clause count doesn't matter)" do
      ast = parse_body("""
      case x do
        :a -> 1
        :b -> 2
        :c -> 3
        :d -> 4
        :e -> 5
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "cond gets +1 per clause beyond the first" do
      ast = parse_body("""
      cond do
        a -> 1
        b -> 2
        true -> 3
      end
      """)
      # cond at depth 0 = +1, plus 2 extra clauses = 3
      assert Complexity.cognitive_complexity(ast) == 3
    end

    test "cond with 1 clause scores 1 (no clause bonus)" do
      ast = parse_body("""
      cond do
        true -> :ok
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "receive scores 1 + depth, clauses don't add" do
      ast = parse_body("""
      receive do
        :msg -> :ok
        :other -> :err
      after
        1000 -> :timeout
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end
  end

  describe "cognitive_complexity/1 boolean operators" do
    test "single boolean operator adds 1 without nesting penalty" do
      ast = parse_body("if a and b, do: :ok")
      # if = +1 (depth 0), and = +1 (no depth penalty)
      assert Complexity.cognitive_complexity(ast) == 2
    end

    test "chained boolean operators each add 1" do
      ast = parse_body("if a and b or c, do: :ok")
      # if = +1, and = +1, or = +1
      assert Complexity.cognitive_complexity(ast) == 3
    end

    test "boolean ops don't increase nesting depth" do
      ast = parse_body("""
      if a && b do
        if c, do: :ok
      end
      """)
      # outer if = +1 (depth 0), && = +1, inner if = +1 + 1 (depth 1)
      assert Complexity.cognitive_complexity(ast) == 4
    end
  end

  describe "cognitive_complexity/1 with" do
    test "with scores 1 + depth" do
      ast = parse_body("""
      with {:ok, a} <- foo(),
           {:ok, b} <- bar(a) do
        a + b
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "with else block is sibling at depth+1 (not deeper)" do
      ast = parse_body("""
      with {:ok, a} <- foo() do
        if a, do: :ok
      else
        :error -> :fail
      end
      """)
      # with = +1 (depth 0), if in do = +1 + 1 (depth 1), else body at depth 1
      assert Complexity.cognitive_complexity(ast) == 3
    end
  end

  describe "cognitive_complexity/1 try" do
    test "try scores 1 + depth" do
      ast = parse_body("""
      try do
        dangerous()
      rescue
        e -> handle(e)
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end

    test "try rescue/catch/after are siblings at depth+1" do
      ast = parse_body("""
      try do
        if x, do: risky()
      rescue
        RuntimeError -> :err
      end
      """)
      # try = +1 (depth 0), if in do block = +1 + 1 (depth 1)
      assert Complexity.cognitive_complexity(ast) == 3
    end
  end

  describe "cognitive_complexity/1 for" do
    test "for comprehension scores 1 + depth" do
      ast = parse_body("""
      for x <- list do
        x * 2
      end
      """)
      assert Complexity.cognitive_complexity(ast) == 1
    end
  end

  describe "cognitive_complexity/1 anonymous functions" do
    test "fn resets depth to 0, costs +1 structural" do
      ast = parse_body("""
      Enum.map(list, fn x ->
        if x > 0, do: x
      end)
      """)
      # fn = +1 (structural break, depth reset to 0)
      # if inside fn = +1 + 0 (depth is 0 inside the lambda)
      assert Complexity.cognitive_complexity(ast) == 2
    end

    test "fn inside nested code resets depth" do
      ast = parse_body("""
      if condition do
        case x do
          :a ->
            Enum.map(list, fn item ->
              if item, do: :yes
            end)
        end
      end
      """)
      # if (depth 0) = +1
      # case (depth 1) = +1 + 1 = 2
      # fn = +1 (structural, depth reset)
      # if inside fn (depth 0) = +1
      # total = 1 + 2 + 1 + 1 = 5
      assert Complexity.cognitive_complexity(ast) == 5
    end
  end

  # ============================================================================
  # Integration tests — compute_all/1 on full file ASTs
  # ============================================================================

  describe "compute_all/1" do
    test "extracts complexity for all functions in a module" do
      ast = parse_file("""
      defmodule Example do
        def simple(x), do: x + 1

        def branchy(x) do
          if x > 0 do
            case x do
              1 -> :one
              _ -> :other
            end
          end
        end

        defp helper(x), do: x
      end
      """)

      result = Complexity.compute_all(ast)

      assert Map.get(result, {:simple, 1}) == 0
      assert Map.get(result, {:helper, 1}) == 0
      # branchy: if (depth 0) = 1, case (depth 1) = 2, total = 3
      assert Map.get(result, {:branchy, 1}) == 3
    end

    test "handles module with no functions" do
      ast = parse_file("""
      defmodule Empty do
        @moduledoc "Nothing here"
      end
      """)

      assert Complexity.compute_all(ast) == %{}
    end

    test "handles multiple modules in one file" do
      ast = parse_file("""
      defmodule A do
        def foo(x), do: if(x, do: 1)
      end

      defmodule B do
        def bar(x) do
          case x do
            :a -> if true, do: 1
            :b -> :ok
          end
        end
      end
      """)

      result = Complexity.compute_all(ast)
      assert Map.get(result, {:foo, 1}) == 1
      # bar: case (depth 0) = 1, if (depth 1) = 2, total = 3
      assert Map.get(result, {:bar, 1}) == 3
    end

    test "graceful on unparseable input" do
      assert Complexity.compute_all(nil) == %{}
      assert Complexity.compute_all(:garbage) == %{}
    end
  end

  # ============================================================================
  # Adversarial tests
  # ============================================================================

  describe "adversarial" do
    test "function with only pattern matching scores 0" do
      ast = parse_file("""
      defmodule PatternMatch do
        def process(%{type: :a, data: d}), do: handle_a(d)
        def process(%{type: :b, data: d}), do: handle_b(d)
        def process(_), do: :unknown
      end
      """)

      result = Complexity.compute_all(ast)
      assert Map.get(result, {:process, 1}) == 0
    end

    test "macro definitions are scored" do
      ast = parse_file("""
      defmodule MyMacro do
        defmacro my_if(condition, do: body) do
          quote do
            if unquote(condition) do
              unquote(body)
            end
          end
        end
      end
      """)

      result = Complexity.compute_all(ast)
      assert is_integer(Map.get(result, {:my_if, 2}, 0))
    end

    test "nested lambdas each reset depth independently" do
      ast = parse_body("""
      Enum.flat_map(a, fn x ->
        Enum.map(x, fn y ->
          if y, do: y
        end)
      end)
      """)
      # outer fn = +1 (reset)
      # inner fn = +1 (reset again)
      # if inside inner fn = +1 (depth 0)
      assert Complexity.cognitive_complexity(ast) == 3
    end

    test "real-world GenServer handle_call pattern" do
      ast = parse_body("""
      case request do
        {:get, key} ->
          if Map.has_key?(state, key) do
            {:reply, Map.get(state, key), state}
          else
            {:reply, nil, state}
          end
        {:put, key, value} ->
          with {:ok, validated} <- validate(value),
               :ok <- check_permissions(key) do
            {:reply, :ok, Map.put(state, key, validated)}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        _ ->
          {:reply, :unknown, state}
      end
      """)
      score = Complexity.cognitive_complexity(ast)
      # case (depth 0) = 1
      # if (depth 1) = 2
      # with (depth 1) = 2
      # total = 5
      assert score == 5
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_body(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  defp parse_file(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end
end
