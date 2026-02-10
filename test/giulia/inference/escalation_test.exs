defmodule Giulia.Inference.EscalationTest do
  @moduledoc """
  Tests for Inference.Escalation — Senior Architect escalation logic.

  Tests cover the pure-functional parts: prompt building, line fix parsing,
  and line number annotation. Provider calls (Groq/Gemini) are not tested
  here as they require external services.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.Escalation

  # ============================================================================
  # build_prompt/3
  # ============================================================================

  describe "build_prompt/3" do
    test "includes file name in prompt" do
      result = Escalation.build_prompt("lib/foo.ex", "defmodule Foo do\nend", "error: undefined")
      assert String.contains?(result, "lib/foo.ex")
    end

    test "includes error in prompt" do
      result = Escalation.build_prompt("lib/foo.ex", "defmodule Foo do\nend", "** (CompileError) undefined function")
      assert String.contains?(result, "CompileError")
    end

    test "includes file content with line numbers" do
      content = "defmodule Foo do\n  def run, do: :ok\nend"
      result = Escalation.build_prompt("lib/foo.ex", content, "error")
      assert String.contains?(result, "   1:")
      assert String.contains?(result, "   2:")
      assert String.contains?(result, "   3:")
    end

    test "truncates long error messages at 1500 chars" do
      long_error = String.duplicate("x", 2000)
      result = Escalation.build_prompt("lib/foo.ex", "code", long_error)
      # The error section should be truncated
      assert String.length(result) < String.length(long_error) + 1000
    end

    test "handles nil file path" do
      result = Escalation.build_prompt(nil, "code", "error")
      assert String.contains?(result, "unknown")
    end

    test "mentions both Option A and Option B formats" do
      result = Escalation.build_prompt("lib/foo.ex", "code", "error")
      assert String.contains?(result, "OPTION A")
      assert String.contains?(result, "OPTION B")
      assert String.contains?(result, "LINE:")
      assert String.contains?(result, "CODE:")
    end
  end

  # ============================================================================
  # parse_line_fix/1
  # ============================================================================

  describe "parse_line_fix/1" do
    test "parses LINE:N CODE:content format" do
      response = "LINE: 42\nCODE: def run(x), do: x + 1"
      assert {:ok, 42, code} = Escalation.parse_line_fix(response)
      assert String.contains?(code, "def run(x)")
    end

    test "parses with code fences stripped" do
      response = "```elixir\nLINE:10\nCODE:  new_line_content\n```"
      assert {:ok, 10, _code} = Escalation.parse_line_fix(response)
    end

    test "case-insensitive LINE matching" do
      response = "line: 5\nCODE: fixed"
      assert {:ok, 5, _} = Escalation.parse_line_fix(response)
    end

    test "case-insensitive CODE matching" do
      response = "LINE: 5\ncode: fixed"
      assert {:ok, 5, _} = Escalation.parse_line_fix(response)
    end

    test "returns error when no LINE found" do
      response = "CODE: something"
      assert {:error, :no_line_number} = Escalation.parse_line_fix(response)
    end

    test "returns error when no CODE found" do
      response = "LINE: 5"
      assert {:error, :no_code_content} = Escalation.parse_line_fix(response)
    end
  end

  # ============================================================================
  # add_line_numbers/1
  # ============================================================================

  describe "add_line_numbers/1" do
    test "adds padded line numbers" do
      content = "line one\nline two\nline three"
      result = Escalation.add_line_numbers(content)
      assert String.contains?(result, "   1: line one")
      assert String.contains?(result, "   2: line two")
      assert String.contains?(result, "   3: line three")
    end

    test "handles nil content" do
      assert "(could not read file)" = Escalation.add_line_numbers(nil)
    end

    test "handles empty string" do
      result = Escalation.add_line_numbers("")
      assert String.contains?(result, "   1: ")
    end

    test "handles single line" do
      result = Escalation.add_line_numbers("hello")
      assert result == "   1: hello"
    end

    test "pads line numbers to 4 chars" do
      lines = Enum.map(1..100, fn i -> "line #{i}" end) |> Enum.join("\n")
      result = Escalation.add_line_numbers(lines)
      assert String.contains?(result, " 100: line 100")
    end
  end
end
