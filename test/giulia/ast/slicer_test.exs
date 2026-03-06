defmodule Giulia.AST.SlicerTest do
  use ExUnit.Case, async: true

  alias Giulia.AST.Slicer

  @sample_source """
  defmodule MyApp.Math do
    def add(a, b), do: a + b

    def multiply(a, b), do: a * b

    defp validate(n) when is_number(n), do: n
  end
  """

  # ============================================================================
  # slice_function/3
  # ============================================================================

  describe "slice_function/3" do
    test "extracts a specific function" do
      {:ok, result} = Slicer.slice_function(@sample_source, :add, 2)
      assert result =~ "add"
      assert result =~ "a + b" or result =~ "+"
    end

    test "returns error for missing function" do
      assert {:error, :function_not_found} =
               Slicer.slice_function(@sample_source, :nonexistent, 0)
    end

    test "matches arity correctly" do
      assert {:error, :function_not_found} =
               Slicer.slice_function(@sample_source, :add, 0)
    end

    test "finds private functions" do
      {:ok, result} = Slicer.slice_function(@sample_source, :validate, 1)
      assert result =~ "validate"
    end
  end

  # ============================================================================
  # slice_function_with_deps/3
  # ============================================================================

  describe "slice_function_with_deps/3" do
    test "returns function source" do
      {:ok, result} = Slicer.slice_function_with_deps(@sample_source, :add, 2)
      assert is_binary(result)
      assert result =~ "add"
    end

    test "returns error for missing function" do
      assert {:error, :not_found} =
               Slicer.slice_function_with_deps(@sample_source, :nope, 0)
    end
  end

  # ============================================================================
  # slice_around_line/3
  # ============================================================================

  describe "slice_around_line/3" do
    test "extracts lines around target" do
      source = Enum.map_join(1..20, "\n", &"line #{&1}")
      result = Slicer.slice_around_line(source, 10, 3)

      assert result =~ ">>> 10:"
      assert result =~ "line 10"
      assert result =~ "line 7"
      assert result =~ "line 13"
    end

    test "marks target line with >>>" do
      source = "a\nb\nc\nd\ne"
      result = Slicer.slice_around_line(source, 3, 1)
      assert result =~ ">>> 3:"
    end

    test "handles beginning of file" do
      source = "first\nsecond\nthird"
      result = Slicer.slice_around_line(source, 1, 5)
      assert result =~ ">>> 1:"
      assert result =~ "first"
    end

    test "handles end of file" do
      source = "a\nb\nc"
      result = Slicer.slice_around_line(source, 3, 5)
      assert result =~ ">>> 3:"
    end

    test "non-binary source returns empty string" do
      assert Slicer.slice_around_line(nil, 1, 5) == ""
    end
  end

  # ============================================================================
  # slice_for_error/3
  # ============================================================================

  describe "slice_for_error/3" do
    test "includes error message" do
      result = Slicer.slice_for_error(@sample_source, 2, "undefined variable")
      assert result =~ "undefined variable"
    end

    test "includes context around error line" do
      source = Enum.map_join(1..10, "\n", &"line #{&1}")
      result = Slicer.slice_for_error(source, 5, "oops")
      assert result =~ "oops"
    end

    test "handles invalid source gracefully" do
      result = Slicer.slice_for_error("not valid elixir {{{{", 1, "parse error")
      assert result =~ "parse error"
    end
  end
end
