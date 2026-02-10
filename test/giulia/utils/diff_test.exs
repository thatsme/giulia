defmodule Giulia.Utils.DiffTest do
  @moduledoc """
  Tests for the line-by-line diff utility.

  Utils.Diff generates unified diffs using List.myers_difference.
  These tests prove:

  1. Identical content produces no diff output
  2. Added/removed/changed lines are correctly marked
  3. Hunk headers (@@ ... @@) are generated
  4. Context lines are included around changes
  5. Truncation works when diff exceeds max_lines
  6. File path headers are added when requested
  7. Colorized output contains ANSI codes
  8. Preview for new files works correctly
  """
  use ExUnit.Case, async: true

  alias Giulia.Utils.Diff

  # ============================================================================
  # Section 1: unified/3 — Basic Diff Generation
  # ============================================================================

  describe "unified/3 — identical content" do
    test "produces empty diff for identical strings" do
      content = "line 1\nline 2\nline 3"
      assert Diff.unified(content, content) == []
    end
  end

  describe "unified/3 — additions" do
    test "marks added lines with +" do
      old = "line 1\nline 3"
      new = "line 1\nline 2\nline 3"
      diff = Diff.unified(old, new)

      # Should contain at least one line starting with "+"
      assert Enum.any?(diff, fn line -> String.contains?(line, "+") and not String.starts_with?(line, "@@") and not String.starts_with?(line, "+++") end)
    end
  end

  describe "unified/3 — deletions" do
    test "marks removed lines with -" do
      old = "line 1\nline 2\nline 3"
      new = "line 1\nline 3"
      diff = Diff.unified(old, new)

      assert Enum.any?(diff, fn line -> String.starts_with?(line, "-") and not String.starts_with?(line, "---") end)
    end
  end

  describe "unified/3 — modifications" do
    test "shows both old and new for changed lines" do
      old = "hello world"
      new = "hello elixir"
      diff = Diff.unified(old, new)

      has_removal = Enum.any?(diff, fn line -> String.starts_with?(line, "-") and not String.starts_with?(line, "---") end)
      has_addition = Enum.any?(diff, fn line -> String.starts_with?(line, "+") and not String.starts_with?(line, "+++") end)

      assert has_removal
      assert has_addition
    end
  end

  # ============================================================================
  # Section 2: Hunk Headers
  # ============================================================================

  describe "unified/3 — hunk headers" do
    test "generates @@ hunk header" do
      old = "line 1\nline 2\nline 3"
      new = "line 1\nline CHANGED\nline 3"
      diff = Diff.unified(old, new)

      assert Enum.any?(diff, fn line -> String.starts_with?(line, "@@") end)
    end
  end

  # ============================================================================
  # Section 3: File Path Headers
  # ============================================================================

  describe "unified/3 — file_path option" do
    test "adds --- and +++ headers when file_path is provided" do
      old = "old content"
      new = "new content"
      diff = Diff.unified(old, new, file_path: "lib/giulia.ex")

      assert Enum.any?(diff, fn line -> String.starts_with?(line, "--- a/lib/giulia.ex") end)
      assert Enum.any?(diff, fn line -> String.starts_with?(line, "+++ b/lib/giulia.ex") end)
    end

    test "no file headers when file_path is not provided" do
      old = "old"
      new = "new"
      diff = Diff.unified(old, new)

      refute Enum.any?(diff, fn line -> String.starts_with?(line, "---") end)
    end
  end

  # ============================================================================
  # Section 4: Truncation
  # ============================================================================

  describe "unified/3 — max_lines truncation" do
    test "truncates and adds message when diff exceeds max_lines" do
      # Create a large diff
      old = Enum.map_join(1..100, "\n", fn i -> "line #{i}" end)
      new = Enum.map_join(1..100, "\n", fn i -> "changed #{i}" end)
      diff = Diff.unified(old, new, max_lines: 10)

      # Should be truncated to ~10 lines + truncation message
      assert length(diff) <= 12
      assert List.last(diff) =~ "more lines"
    end

    test "no truncation message when diff fits within max_lines" do
      old = "line 1"
      new = "line 2"
      diff = Diff.unified(old, new, max_lines: 50)

      refute Enum.any?(diff, fn line -> String.contains?(line, "more lines") end)
    end
  end

  # ============================================================================
  # Section 5: Context Lines
  # ============================================================================

  describe "unified/3 — context option" do
    test "includes context lines around changes" do
      # 10 lines, change only line 5
      old_lines = Enum.map(1..10, fn i -> "line #{i}" end)
      new_lines = List.replace_at(old_lines, 4, "CHANGED line 5")
      old = Enum.join(old_lines, "\n")
      new = Enum.join(new_lines, "\n")

      diff = Diff.unified(old, new, context: 2)

      # Context lines start with " "
      context_lines = Enum.filter(diff, fn line ->
        String.starts_with?(line, " ") and not String.starts_with?(line, " @@")
      end)

      # Should have some context lines (at least 2 before + 2 after)
      assert length(context_lines) >= 2
    end
  end

  # ============================================================================
  # Section 6: colorized/3 — ANSI Output
  # ============================================================================

  describe "colorized/3" do
    test "returns a string (not a list)" do
      old = "hello"
      new = "world"
      result = Diff.colorized(old, new)

      assert is_binary(result)
    end

    test "contains ANSI escape codes" do
      old = "hello"
      new = "world"
      result = Diff.colorized(old, new)

      # ANSI escape codes start with \e[
      assert result =~ "\e["
    end

    test "empty diff produces empty colorized output" do
      content = "same content"
      result = Diff.colorized(content, content)

      assert result == ""
    end
  end

  # ============================================================================
  # Section 7: preview_new/2 — New File Preview
  # ============================================================================

  describe "preview_new/2" do
    test "returns string with green ANSI codes" do
      content = "defmodule Foo do\n  def bar, do: :ok\nend"
      result = Diff.preview_new(content, file_path: "lib/foo.ex")

      assert is_binary(result)
      assert result =~ "\e[32m"  # Green
      assert result =~ "lib/foo.ex"
    end

    test "shows line numbers" do
      content = "line one\nline two\nline three"
      result = Diff.preview_new(content)

      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "3"
    end

    test "truncates long files" do
      content = Enum.map_join(1..100, "\n", fn i -> "line #{i}" end)
      result = Diff.preview_new(content, max_lines: 5)

      assert result =~ "more lines"
    end
  end
end
