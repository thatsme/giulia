defmodule Giulia.Inference.RenameMFATest do
  @moduledoc """
  Tests for Inference.RenameMFA — AST-based function rename.

  Tests cover the pure-functional AST helpers: arity detection,
  line-level rename, module matching, and segment extraction.
  The full execute/3 flow requires ETS + Knowledge Graph so is
  not tested here.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.RenameMFA

  # ============================================================================
  # detect_arity_range/3
  # ============================================================================

  describe "detect_arity_range/3" do
    test "simple function returns single arity" do
      source = """
      defmodule Foo do
        def run(x) do
          x + 1
        end
      end
      """

      assert [1] = RenameMFA.detect_arity_range(source, :run, 1)
    end

    test "function with default args returns range" do
      source = """
      defmodule Foo do
        def execute(name, args, opts \\\\ []) do
          {name, args, opts}
        end
      end
      """

      result = RenameMFA.detect_arity_range(source, :execute, 3)
      assert 2 in result
      assert 3 in result
    end

    test "function with multiple defaults expands range" do
      source = """
      defmodule Foo do
        def call(a, b \\\\ nil, c \\\\ []) do
          {a, b, c}
        end
      end
      """

      result = RenameMFA.detect_arity_range(source, :call, 3)
      assert 1 in result
      assert 2 in result
      assert 3 in result
    end

    test "zero-arity function returns [0]" do
      source = """
      defmodule Foo do
        def start do
          :ok
        end
      end
      """

      assert [0] = RenameMFA.detect_arity_range(source, :start, 0)
    end

    test "unrelated function names are ignored" do
      source = """
      defmodule Foo do
        def other(x, y) do
          x + y
        end
      end
      """

      # Looking for :run which doesn't exist, should return declared arity
      assert [1] = RenameMFA.detect_arity_range(source, :run, 1)
    end

    test "unparseable source returns declared arity" do
      source = "this is not valid elixir {{{{"
      assert [2] = RenameMFA.detect_arity_range(source, :func, 2)
    end
  end

  # ============================================================================
  # rename_on_line/3
  # ============================================================================

  describe "rename_on_line/3" do
    test "renames function call" do
      line = "    result = MyModule.old_name(arg1, arg2)"
      assert "    result = MyModule.new_name(arg1, arg2)" = RenameMFA.rename_on_line(line, "old_name", "new_name")
    end

    test "renames function definition" do
      line = "  def old_name(x) do"
      assert "  def new_name(x) do" = RenameMFA.rename_on_line(line, "old_name", "new_name")
    end

    test "renames private function definition" do
      line = "  defp old_name(x, y) do"
      assert "  defp new_name(x, y) do" = RenameMFA.rename_on_line(line, "old_name", "new_name")
    end

    test "does not rename partial word matches" do
      line = "  old_name_extended(x)"
      # The regex uses \b boundary, so old_name( should not match old_name_extended(
      result = RenameMFA.rename_on_line(line, "old_name", "new_name")
      # old_name_extended does not have old_name( pattern — should be unchanged
      assert result == line
    end

    test "renames multiple occurrences on same line" do
      line = "  old_name(old_name(x))"
      result = RenameMFA.rename_on_line(line, "old_name", "new_name")
      assert result == "  new_name(new_name(x))"
    end

    test "handles special regex chars in names" do
      line = "  my_func(x)"
      # Underscores are safe in regex
      assert "  renamed(x)" = RenameMFA.rename_on_line(line, "my_func", "renamed")
    end
  end

  # ============================================================================
  # rename_in_source/7
  # ============================================================================

  describe "rename_in_source/7" do
    test "renames function definition in target module" do
      source = """
      defmodule Alpha do
        def old_func(x) do
          x + 1
        end
      end
      """

      {new_source, count} = RenameMFA.rename_in_source(
        source, "Alpha", :old_func, "old_func", "new_func", [1],
        is_target: true
      )

      assert count > 0
      assert String.contains?(new_source, "new_func")
      refute String.contains?(new_source, "old_func")
    end

    test "renames local calls within target module" do
      source = """
      defmodule Alpha do
        def run(x) do
          old_func(x)
        end

        def old_func(x), do: x * 2
      end
      """

      {new_source, count} = RenameMFA.rename_in_source(
        source, "Alpha", :old_func, "old_func", "new_func", [1],
        is_target: true
      )

      assert count >= 2  # def + local call
      assert String.contains?(new_source, "new_func(x)")
    end

    test "returns 0 changes for non-matching module" do
      source = """
      defmodule Other do
        def other_func(x), do: x
      end
      """

      {_new_source, count} = RenameMFA.rename_in_source(
        source, "Alpha", :old_func, "old_func", "new_func", [1],
        is_target: false, is_caller: true
      )

      assert count == 0
    end

    test "handles unparseable source gracefully" do
      source = "this is not valid elixir {{{{"

      {returned_source, count} = RenameMFA.rename_in_source(
        source, "Alpha", :func, "func", "new_func", [1],
        is_target: true
      )

      assert count == 0
      assert returned_source == source
    end
  end

  # ============================================================================
  # ast_matches_module?/2
  # ============================================================================

  describe "ast_matches_module?/2" do
    test "matches full alias AST node" do
      alias_node = {:__aliases__, [], [:Alpha, :Beta]}
      assert RenameMFA.ast_matches_module?(alias_node, "Alpha.Beta")
    end

    test "matches last segment" do
      alias_node = {:__aliases__, [], [:Beta]}
      assert RenameMFA.ast_matches_module?(alias_node, "Alpha.Beta")
    end

    test "matches atom module name" do
      assert RenameMFA.ast_matches_module?(:Alpha, "Alpha")
    end

    test "does not match unrelated module" do
      alias_node = {:__aliases__, [], [:Gamma]}
      refute RenameMFA.ast_matches_module?(alias_node, "Alpha.Beta")
    end

    test "non-alias/non-atom returns false" do
      refute RenameMFA.ast_matches_module?("string", "Module")
      refute RenameMFA.ast_matches_module?(42, "Module")
    end
  end

  # ============================================================================
  # last_segment/1
  # ============================================================================

  describe "last_segment/1" do
    test "extracts last segment from dotted name" do
      assert "Registry" = RenameMFA.last_segment("Giulia.Tools.Registry")
    end

    test "returns name when no dots" do
      assert "Alpha" = RenameMFA.last_segment("Alpha")
    end

    test "handles deeply nested modules" do
      assert "Deep" = RenameMFA.last_segment("A.B.C.D.Deep")
    end
  end

  # ============================================================================
  # execute/3 — validation only
  # ============================================================================

  describe "execute/3 validation" do
    test "returns error for missing module" do
      params = %{"module" => nil, "old_name" => "func", "new_name" => "new_func", "arity" => 1}
      assert {:error, msg} = RenameMFA.execute(params, %Giulia.Inference.Transaction{}, [])
      assert String.contains?(msg, "module")
    end

    test "returns error for missing old_name" do
      params = %{"module" => "Foo", "old_name" => "", "new_name" => "new_func", "arity" => 1}
      assert {:error, msg} = RenameMFA.execute(params, %Giulia.Inference.Transaction{}, [])
      assert String.contains?(msg, "old_name")
    end

    test "returns error for missing new_name" do
      params = %{"module" => "Foo", "old_name" => "func", "new_name" => nil, "arity" => 1}
      assert {:error, msg} = RenameMFA.execute(params, %Giulia.Inference.Transaction{}, [])
      assert String.contains?(msg, "new_name")
    end

    test "returns error for missing arity" do
      params = %{"module" => "Foo", "old_name" => "func", "new_name" => "new_func", "arity" => nil}
      assert {:error, msg} = RenameMFA.execute(params, %Giulia.Inference.Transaction{}, [])
      assert String.contains?(msg, "arity")
    end

    test "returns error when old_name equals new_name" do
      params = %{"module" => "Foo", "old_name" => "func", "new_name" => "func", "arity" => 1}
      assert {:error, msg} = RenameMFA.execute(params, %Giulia.Inference.Transaction{}, [])
      assert String.contains?(msg, "identical")
    end
  end
end
