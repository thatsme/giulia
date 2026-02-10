defmodule Giulia.StructuredOutput.ParserTest do
  @moduledoc """
  Tests for the hybrid format parser.

  StructuredOutput.Parser handles the 4-tier fallback for parsing
  model responses into structured tool calls:

  1. <payload> tags — explicit code separation
  2. <action> + trailing fenced code — implicit code extraction
  3. <action> only — non-code tools
  4. Plain JSON fallback

  These tests prove each tier works independently, the fallback
  chain is correct, and edge cases (malformed JSON, unclosed tags,
  multi-action batches) are handled gracefully.
  """
  use ExUnit.Case, async: true

  alias Giulia.StructuredOutput.Parser

  # ============================================================================
  # Section 1: hybrid_format?/1 — Format Detection
  # ============================================================================

  describe "hybrid_format?/1" do
    test "returns true when <payload> tag present" do
      assert Parser.hybrid_format?("<action>{}</action><payload>code</payload>")
    end

    test "returns false when no <payload> tag" do
      refute Parser.hybrid_format?("<action>{\"tool\":\"read_file\"}</action>")
    end

    test "returns false for plain JSON" do
      refute Parser.hybrid_format?("{\"tool\":\"read_file\"}")
    end

    test "returns false for non-string input" do
      refute Parser.hybrid_format?(nil)
      refute Parser.hybrid_format?(42)
      refute Parser.hybrid_format?(%{})
    end
  end

  # ============================================================================
  # Section 2: Tier 1 — <action> + <payload> Tags
  # ============================================================================

  describe "parse_response/1 — Tier 1: payload tags" do
    test "extracts tool, params, and code from payload" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Giulia.Foo","function":"bar","arity":1}}</action>
      <payload>
      def bar(x) do
        x + 1
      end
      </payload>
      """

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "patch_function"
      assert result["parameters"]["module"] == "Giulia.Foo"
      assert result["parameters"]["code"] =~ "def bar(x)"
    end

    test "returns error when <payload> present but <action> missing" do
      response = "<payload>some code</payload>"
      assert {:error, :missing_action_tag} = Parser.parse_response(response)
    end
  end

  # ============================================================================
  # Section 3: Tier 2 — <action> + Trailing Fenced Code
  # ============================================================================

  describe "parse_response/1 — Tier 2: action + trailing code" do
    test "extracts code from fenced elixir block after </action>" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>

      ```elixir
      def bar do
        :hello_world
      end
      ```
      """

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "patch_function"
      assert result["parameters"]["code"] =~ "def bar"
    end

    test "does not inject trailing code for non-code tools" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"lib/foo.ex"}}</action>

      ```elixir
      some code here
      ```
      """

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
      refute Map.has_key?(result["parameters"], "code")
      assert result["parameters"]["path"] == "lib/foo.ex"
    end
  end

  # ============================================================================
  # Section 4: Tier 3 — <action> Only (Non-Code Tools)
  # ============================================================================

  describe "parse_response/1 — Tier 3: action only" do
    test "parses simple tool call without code" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"lib/giulia.ex"}}</action>
      """

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
      assert result["parameters"]["path"] == "lib/giulia.ex"
    end

    test "handles tool call with no parameters key" do
      response = "<action>{\"tool\":\"think\"}</action>"

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
      assert result["parameters"] == %{}
    end

    test "handles unclosed action tag" do
      response = "<action>{\"tool\":\"respond\",\"parameters\":{\"message\":\"Hello\"}}"

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "respond"
      assert result["parameters"]["message"] == "Hello"
    end
  end

  # ============================================================================
  # Section 5: Tier 4 — Plain JSON Fallback
  # ============================================================================

  describe "parse_response/1 — Tier 4: plain JSON" do
    test "parses raw JSON tool call" do
      response = ~s({"tool":"read_file","parameters":{"path":"mix.exs"}})

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
      assert result["parameters"]["path"] == "mix.exs"
    end

    test "parses clean JSON without prose" do
      response = ~s({"tool":"read_file","parameters":{"path":"lib/giulia.ex"}})

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
    end

    test "returns error for completely unparseable input" do
      response = "This is just plain text with no JSON or tags."
      assert {:error, _reason} = Parser.parse_response(response)
    end
  end

  # ============================================================================
  # Section 6: Non-String Input
  # ============================================================================

  describe "parse_response/1 — invalid input" do
    test "returns error for nil" do
      assert {:error, :not_a_string} = Parser.parse_response(nil)
    end

    test "returns error for integer" do
      assert {:error, :not_a_string} = Parser.parse_response(42)
    end

    test "returns error for map" do
      assert {:error, :not_a_string} = Parser.parse_response(%{tool: "read_file"})
    end
  end

  # ============================================================================
  # Section 7: JSON Repair
  # ============================================================================

  describe "parse_response/1 — JSON repair" do
    test "repairs malformed JSON by extracting tool name" do
      # Simulates a model that produces broken JSON inside <action>
      response = ~s(<action>{"tool": "read_file", "parameters": {"path": "lib/foo.ex"</action>)

      assert {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
    end
  end

  # ============================================================================
  # Section 8: Multi-Action Parsing
  # ============================================================================

  describe "parse_all_actions/1" do
    test "extracts multiple action blocks" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"lib/a.ex"}}</action>
      <action>{"tool":"read_file","parameters":{"path":"lib/b.ex"}}</action>
      """

      assert {:ok, actions} = Parser.parse_all_actions(response)
      assert length(actions) == 2
      assert Enum.at(actions, 0)["parameters"]["path"] == "lib/a.ex"
      assert Enum.at(actions, 1)["parameters"]["path"] == "lib/b.ex"
    end

    test "returns single action in list for one block" do
      response = ~s(<action>{"tool":"think","parameters":{}}</action>)

      assert {:ok, [action]} = Parser.parse_all_actions(response)
      assert action["tool"] == "think"
    end

    test "returns error when no actions found" do
      assert {:error, :no_actions_found} = Parser.parse_all_actions("no actions here")
    end

    test "handles code tools in multi-action with trailing code" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"lib/a.ex"}}</action>
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>

      ```elixir
      def bar, do: :ok
      ```
      """

      assert {:ok, actions} = Parser.parse_all_actions(response)
      assert length(actions) == 2
      assert Enum.at(actions, 0)["tool"] == "read_file"
      assert Enum.at(actions, 1)["tool"] == "patch_function"
    end
  end
end
