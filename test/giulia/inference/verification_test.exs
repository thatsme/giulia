defmodule Giulia.Inference.VerificationTest do
  @moduledoc """
  Tests for Inference.Verification — compilation result parsing.

  Pure-functional module: parse compile output, extract errors/warnings,
  build BUILD GREEN observation strings.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.Verification

  # ============================================================================
  # parse_compile_result/1
  # ============================================================================

  describe "parse_compile_result/1" do
    test "clean output returns :success" do
      assert :success = Verification.parse_compile_result("Compiling 3 files (.ex)\nGenerated giulia app")
    end

    test "empty string returns :success" do
      assert :success = Verification.parse_compile_result("")
    end

    test "output with warning: returns {:warnings, text}" do
      output = """
      warning: variable x is unused
        lib/foo.ex:10
      """

      assert {:warnings, text} = Verification.parse_compile_result(output)
      assert String.contains?(text, "warning:")
    end

    test "output with ** ( returns {:error, text}" do
      output = """
      ** (CompileError) lib/foo.ex:10: undefined function bar/0
      """

      assert {:error, text} = Verification.parse_compile_result(output)
      assert String.contains?(text, "CompileError")
    end

    test "output with non-zero exit code returns {:error, text}" do
      output = """
      Compiling 1 file (.ex)
      error[E001]: undefined function
      Exit code: 1
      """

      assert {:error, _text} = Verification.parse_compile_result(output)
    end

    test "exit code 0 is not treated as error" do
      output = "Compiling 1 file (.ex)\nExit code: 0"
      assert :success = Verification.parse_compile_result(output)
    end

    test "compile error regex matches error[...] format" do
      output = """
      error[E001]: undefined function run/0
        lib/foo.ex:5
      """

      assert {:error, _} = Verification.parse_compile_result(output)
    end
  end

  # ============================================================================
  # extract_compile_errors/1
  # ============================================================================

  describe "extract_compile_errors/1" do
    test "extracts lines containing error keywords" do
      output = """
      Compiling 1 file (.ex)
      ** (CompileError) lib/foo.ex:5: undefined function bar/0
        (elixir) lib/kernel/parallel_compiler.ex:230
      """

      result = Verification.extract_compile_errors(output)
      assert String.contains?(result, "CompileError")
    end

    test "extracts lines with pipe context markers" do
      output = """
         |
       5 | def run(x) = x
         |     ^
      error: unexpected token
      """

      result = Verification.extract_compile_errors(output)
      assert String.contains?(result, "|")
    end

    test "falls back to raw tail when no specific errors found" do
      output = "some random output\nwith no matching keywords\njust plain text"
      result = Verification.extract_compile_errors(output)
      assert String.contains?(result, "couldn't parse a specific error")
    end

    test "limits to 30 error lines" do
      lines = Enum.map(1..50, fn i -> "error: line #{i}" end) |> Enum.join("\n")
      result = Verification.extract_compile_errors(lines)
      count = result |> String.split("\n") |> length()
      assert count <= 30
    end
  end

  # ============================================================================
  # extract_compile_warnings/1
  # ============================================================================

  describe "extract_compile_warnings/1" do
    test "extracts warning lines" do
      output = """
      Compiling 2 files (.ex)
      warning: variable x is unused
        lib/foo.ex:10
      warning: function bar/0 is unused
        lib/foo.ex:20
      Generated giulia app
      """

      result = Verification.extract_compile_warnings(output)
      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert Enum.all?(lines, &String.contains?(&1, "warning:"))
    end

    test "limits to 10 warning lines" do
      lines = Enum.map(1..20, fn i -> "warning: unused var #{i}" end) |> Enum.join("\n")
      result = Verification.extract_compile_warnings(lines)
      count = result |> String.split("\n") |> length()
      assert count <= 10
    end

    test "returns empty string when no warnings" do
      assert "" == Verification.extract_compile_warnings("Compiling 1 file (.ex)\nGenerated app")
    end
  end

  # ============================================================================
  # build_green_observation/5
  # ============================================================================

  describe "build_green_observation/5" do
    test "builds basic observation without extras" do
      result = Verification.build_green_observation("edit_file", {:ok, "done"}, nil, "", nil)
      assert String.contains?(result, "BUILD GREEN")
      assert String.contains?(result, "COMPLETE")
    end

    test "includes warnings section when provided" do
      result = Verification.build_green_observation("edit_file", {:ok, "done"}, "warning: unused", "", nil)
      assert String.contains?(result, "Compiler warnings")
      assert String.contains?(result, "warning: unused")
    end

    test "includes test summary when provided" do
      result = Verification.build_green_observation("edit_file", {:ok, "done"}, nil, "", "3 tests, 0 failures")
      assert String.contains?(result, "AUTO-REGRESSION")
      assert String.contains?(result, "3 tests, 0 failures")
    end

    test "includes test hint" do
      result = Verification.build_green_observation("edit_file", {:ok, "done"}, nil, "run tests!", nil)
      assert String.contains?(result, "run tests!")
    end
  end
end
