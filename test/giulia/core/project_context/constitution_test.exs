defmodule Giulia.Core.ProjectContext.ConstitutionTest do
  use ExUnit.Case, async: true

  alias Giulia.Core.ProjectContext.Constitution

  @sample_constitution """
  # GIULIA.md

  **Language**: Elixir
  **Framework**: Phoenix

  ## Architectural Guidelines
  - Use context modules for business logic
  - Keep controllers thin

  ## Taboos
  - Never use umbrella projects
  - Never add dependencies without approval

  ## Preferred Patterns
  * Use Ecto changesets for validation
  * Prefer pattern matching over conditionals
  """

  # ============================================================================
  # parse/1
  # ============================================================================

  describe "parse/1" do
    test "extracts rules from Architectural Guidelines section" do
      result = Constitution.parse(@sample_constitution)
      assert "Use context modules for business logic" in result.rules
      assert "Keep controllers thin" in result.rules
    end

    test "extracts taboos" do
      result = Constitution.parse(@sample_constitution)
      assert "Never use umbrella projects" in result.taboos
      assert "Never add dependencies without approval" in result.taboos
    end

    test "extracts patterns with asterisk bullets" do
      result = Constitution.parse(@sample_constitution)
      assert "Use Ecto changesets for validation" in result.patterns
      assert "Prefer pattern matching over conditionals" in result.patterns
    end

    test "extracts tech stack" do
      result = Constitution.parse(@sample_constitution)
      assert result.tech_stack.language == "Elixir"
      assert result.tech_stack.framework == "Phoenix"
    end

    test "preserves raw content" do
      result = Constitution.parse(@sample_constitution)
      assert result.raw == @sample_constitution
    end

    test "handles missing sections gracefully" do
      result = Constitution.parse("# Just a title\nSome text")
      assert result.rules == []
      assert result.taboos == []
      assert result.patterns == []
    end

    test "handles empty content" do
      result = Constitution.parse("")
      assert result.rules == []
      assert result.taboos == []
      assert result.patterns == []
      assert result.tech_stack == %{language: nil, framework: nil}
    end
  end

  # ============================================================================
  # load/1
  # ============================================================================

  describe "load/1" do
    test "loads and parses a real file" do
      path = Path.join(System.tmp_dir!(), "giulia_test_constitution_#{:rand.uniform(10000)}.md")
      File.write!(path, @sample_constitution)

      result = Constitution.load(path)
      assert result.raw == @sample_constitution
      assert length(result.rules) == 2

      File.rm!(path)
    end

    test "returns empty constitution for missing file" do
      result = Constitution.load("/nonexistent/path/GIULIA.md")
      assert result.raw == nil
      assert result.rules == []
      assert result.taboos == []
      assert result.patterns == []
    end
  end

  # ============================================================================
  # determine_provider/1
  # ============================================================================

  describe "determine_provider/1" do
    test "returns :cloud for Phoenix projects" do
      constitution = %{tech_stack: %{framework: "Phoenix"}}
      assert Constitution.determine_provider(constitution) == :cloud
    end

    test "returns :auto for non-Phoenix projects" do
      constitution = %{tech_stack: %{framework: "Nerves"}}
      assert Constitution.determine_provider(constitution) == :auto
    end

    test "returns :auto for nil tech_stack" do
      assert Constitution.determine_provider(%{}) == :auto
    end

    test "returns :auto for nil constitution" do
      assert Constitution.determine_provider(nil) == :auto
    end
  end

  # ============================================================================
  # Adversarial inputs
  # ============================================================================

  describe "adversarial inputs" do
    test "handles section with no bullets" do
      content = "## Taboos\nJust plain text, no bullets."
      result = Constitution.parse(content)
      assert result.taboos == []
    end

    test "handles mixed bullet styles" do
      content = """
      ## Taboos
      - Dash bullet
      * Star bullet
      - Another dash
      """
      result = Constitution.parse(content)
      assert length(result.taboos) == 3
    end

    test "handles unicode in content" do
      content = """
      **Language**: Ελληνικά
      ## Taboos
      - Μη χρησιμοποιείτε umbrella
      """
      result = Constitution.parse(content)
      assert result.tech_stack.language == "Ελληνικά"
      assert length(result.taboos) == 1
    end

    test "handles very long lines" do
      long_line = String.duplicate("x", 10_000)
      content = "## Taboos\n- #{long_line}"
      result = Constitution.parse(content)
      assert length(result.taboos) == 1
      assert String.length(hd(result.taboos)) == 10_000
    end
  end
end
