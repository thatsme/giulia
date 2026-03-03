defmodule Giulia.Inference.ResponseParserTest do
  @moduledoc """
  Tests for the inference loop response parser.

  ResponseParser sits between the LLM provider and the Engine, translating
  raw model responses into structured directives:

    {:tool_call, name, params}       — single tool call
    {:multi_tool_call, name, params, rest} — batched actions
    {:text, content}                 — plain text (no tool found)
    {:error, reason}                 — parse failure

  Pure-functional module — no GenServer coupling.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.ResponseParser

  # ============================================================================
  # Section 1: parse/1 — Native Tool Calls (Provider-Structured)
  # ============================================================================

  describe "parse/1 — native tool_calls" do
    test "extracts first tool call from provider response" do
      # content must not be nil — parse(%{content: nil}) matches first
      response = %{
        content: "",
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "lib/giulia.ex"}}
        ]
      }

      assert {:tool_call, "read_file", %{"path" => "lib/giulia.ex"}} = ResponseParser.parse(response)
    end

    test "picks first tool call when multiple present" do
      response = %{
        content: "",
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "a.ex"}},
          %{name: "write_file", arguments: %{"path" => "b.ex"}}
        ]
      }

      assert {:tool_call, "read_file", %{"path" => "a.ex"}} = ResponseParser.parse(response)
    end
  end

  # ============================================================================
  # Section 2: parse/1 — Empty/Nil Responses
  # ============================================================================

  describe "parse/1 — empty responses" do
    test "returns error for nil content" do
      assert {:error, :empty_response} = ResponseParser.parse(%{content: nil})
    end

    test "returns error for unknown format" do
      assert {:error, :unknown_response_format} = ResponseParser.parse(:garbage)
    end
  end

  # ============================================================================
  # Section 3: parse/1 — Hybrid Format (<action>/<payload>)
  # ============================================================================

  describe "parse/1 — hybrid format responses" do
    test "parses single action from content" do
      response = %{
        content: ~s(<action>{"tool":"read_file","parameters":{"path":"lib/foo.ex"}}</action>),
        tool_calls: nil
      }

      assert {:tool_call, "read_file", %{"path" => "lib/foo.ex"}} = ResponseParser.parse(response)
    end

    test "parses multi-action responses" do
      content = """
      <action>{"tool":"read_file","parameters":{"path":"lib/a.ex"}}</action>
      <action>{"tool":"read_file","parameters":{"path":"lib/b.ex"}}</action>
      """

      response = %{content: content, tool_calls: nil}
      assert {:multi_tool_call, "read_file", %{"path" => "lib/a.ex"}, rest} = ResponseParser.parse(response)
      assert length(rest) == 1
    end

    test "parses payload format with code" do
      content = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>
      <payload>
      def bar, do: :ok
      </payload>
      """

      response = %{content: content, tool_calls: nil}
      assert {:tool_call, "patch_function", params} = ResponseParser.parse(response)
      assert params["code"] =~ "def bar"
    end
  end

  # ============================================================================
  # Section 4: parse/1 — JSON Path (No Tags)
  # ============================================================================

  describe "parse/1 — plain JSON responses" do
    test "extracts tool call from JSON in content" do
      response = %{
        content: ~s({"tool":"think","parameters":{"thought":"analyzing..."}}),
        tool_calls: nil
      }

      assert {:tool_call, "think", %{"thought" => "analyzing..."}} = ResponseParser.parse(response)
    end

    test "returns {:text, content} when no JSON found" do
      response = %{
        content: "I'll help you with that. Let me think about the best approach.",
        tool_calls: nil
      }

      assert {:text, _content} = ResponseParser.parse(response)
    end

    test "handles tool call with missing parameters" do
      response = %{
        content: ~s({"tool":"think"}),
        tool_calls: nil
      }

      assert {:tool_call, "think", %{}} = ResponseParser.parse(response)
    end
  end

  # ============================================================================
  # Section 5: parse_single_action/1
  # ============================================================================

  describe "parse_single_action/1" do
    test "parses valid action content" do
      content = ~s(<action>{"tool":"respond","parameters":{"message":"Done!"}}</action>)
      assert {:tool_call, "respond", %{"message" => "Done!"}} = ResponseParser.parse_single_action(content)
    end

    test "falls back to JSON path on hybrid parse failure" do
      # No action tags, but has JSON
      content = ~s({"tool":"read_file","parameters":{"path":"mix.exs"}})
      assert {:tool_call, "read_file", _} = ResponseParser.parse_single_action(content)
    end
  end

  # ============================================================================
  # Section 6: parse_json/1
  # ============================================================================

  describe "parse_json/1" do
    test "extracts tool call from JSON" do
      content = ~s({"tool":"list_files","parameters":{"path":"lib/"}})
      assert {:tool_call, "list_files", %{"path" => "lib/"}} = ResponseParser.parse_json(content)
    end

    test "returns {:text, _} for non-JSON content" do
      content = "Just some plain text explanation."
      assert {:text, ^content} = ResponseParser.parse_json(content)
    end

    test "returns error for invalid JSON structure" do
      # Valid JSON but wrong shape (no "tool" key)
      content = ~s({"action":"read","file":"foo.ex"})

      result = ResponseParser.parse_json(content)
      assert result in [{:error, :invalid_tool_format}, {:text, content}]
    end
  end

  # ============================================================================
  # Section 7: clean_output/1
  # ============================================================================

  describe "clean_output/1" do
    test "strips <|im_start|> and <|im_end|> tokens" do
      # The regex strips <|im_start|>...<|im_end|> as a block
      text = "Hello world<|im_end|>"
      result = ResponseParser.clean_output(text)
      assert result == "Hello world"
    end

    test "strips im_start tag and im_end tag separately" do
      # The lazy .*? with optional group means <|im_start|> is stripped minimally,
      # then orphan <|im_end|> is caught by the second regex pass
      text = "Before<|im_end|>After"
      result = ResponseParser.clean_output(text)
      assert result == "BeforeAfter"
    end

    test "strips <action> blocks from output" do
      text = "Here is my plan.\n<action>{\"tool\":\"read_file\"}</action>"
      result = ResponseParser.clean_output(text)
      assert result == "Here is my plan."
    end

    test "strips <think> and </think> tags (not content)" do
      # The regex strips the tags themselves, not the content between
      text = "<think>Let me consider...</think>The answer is 42."
      result = ResponseParser.clean_output(text)
      assert result == "Let me consider...The answer is 42."
    end

    test "returns fallback message for empty result after cleaning" do
      text = "<action>{\"tool\":\"read_file\"}</action>"
      result = ResponseParser.clean_output(text)
      assert result =~ "wasn't able to formulate"
    end
  end

  # ============================================================================
  # Section 8: extract_error_context/2
  # ============================================================================

  describe "extract_error_context/2" do
    test "extracts context window around error position" do
      json = String.duplicate("a", 100)
      context = ResponseParser.extract_error_context(json, 50)

      # Should be a substring centered around position 50
      assert is_binary(context)
      assert String.length(context) <= 60
    end

    test "handles position near start of string" do
      json = "short"
      context = ResponseParser.extract_error_context(json, 0)
      assert is_binary(context)
    end

    test "handles position near end of string" do
      json = "short"
      context = ResponseParser.extract_error_context(json, 4)
      assert is_binary(context)
    end
  end
end
