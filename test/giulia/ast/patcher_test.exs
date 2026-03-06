defmodule Giulia.AST.PatcherTest do
  use ExUnit.Case, async: true

  alias Giulia.AST.Patcher

  @sample_source """
  defmodule MyApp.Calc do
    def add(a, b), do: a + b

    def subtract(a, b), do: a - b

    defp internal, do: :ok
  end
  """

  # ============================================================================
  # patch_function/4
  # ============================================================================

  describe "patch_function/4" do
    test "replaces a function body" do
      new_body = "def add(a, b), do: a + b + 1"
      {:ok, result} = Patcher.patch_function(@sample_source, :add, 2, new_body)
      assert is_binary(result)
    end

    test "leaves other functions unchanged" do
      new_body = "def add(a, b), do: :replaced"
      {:ok, result} = Patcher.patch_function(@sample_source, :add, 2, new_body)
      assert result =~ "subtract"
    end

    test "returns error for invalid source" do
      assert {:error, _} = Patcher.patch_function("{{invalid", :add, 2, "def add, do: :ok")
    end

    test "returns error for invalid new body" do
      assert {:error, _} = Patcher.patch_function(@sample_source, :add, 2, "{{invalid")
    end
  end

  # ============================================================================
  # insert_function/3
  # ============================================================================

  describe "insert_function/3" do
    test "inserts a function into a module" do
      new_func = "def multiply(a, b), do: a * b"
      {:ok, result} = Patcher.insert_function(@sample_source, "MyApp.Calc", new_func)
      assert result =~ "multiply"
    end

    test "returns error for invalid function source" do
      assert {:error, _} = Patcher.insert_function(@sample_source, "MyApp.Calc", "{{invalid")
    end
  end

  # ============================================================================
  # get_function_range/3
  # ============================================================================

  describe "get_function_range/3" do
    setup do
      {:ok, ast} = Sourceror.parse_string(@sample_source)
      %{ast: ast}
    end

    test "finds function line range", %{ast: ast} do
      {:ok, {start_line, end_line}} = Patcher.get_function_range(ast, :add, 2)
      assert is_integer(start_line)
      assert is_integer(end_line)
      assert start_line > 0
      assert end_line >= start_line
    end

    test "returns :not_found for missing function", %{ast: ast} do
      assert :not_found = Patcher.get_function_range(ast, :nonexistent, 0)
    end

    test "matches arity", %{ast: ast} do
      assert :not_found = Patcher.get_function_range(ast, :add, 0)
    end
  end
end
