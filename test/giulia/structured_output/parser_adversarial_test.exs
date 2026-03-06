defmodule Giulia.StructuredOutput.ParserAdversarialTest do
  @moduledoc """
  Adversarial tests for StructuredOutput.Parser.

  Real LLM outputs are messy. Small models (3B) produce:
  - JSON with unescaped newlines, tabs, backticks inside strings
  - Nested markdown fences (code containing ```)
  - Truncated responses (connection drop mid-stream)
  - Multiple <action> tags with only some valid
  - Injection attempts (tool name = "../../../etc/passwd")
  - Mixed formats in single response (action + plain JSON)
  - Unicode in tool names and parameters
  - Extremely long responses (token limit exhaustion)
  - Empty/whitespace-only tags
  - HTML-like entities in JSON values
  """
  use ExUnit.Case, async: true

  alias Giulia.StructuredOutput.Parser

  # ============================================================================
  # 1. Malformed JSON inside <action> tags
  # ============================================================================

  describe "malformed JSON in action tags" do
    test "single quotes instead of double quotes" do
      response = "<action>{'tool': 'read_file', 'parameters': {'path': 'lib/foo.ex'}}</action>"
      # Jason requires double quotes — should repair or fail gracefully
      result = Parser.parse_response(response)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "trailing comma in JSON object" do
      response = ~s(<action>{"tool": "read_file", "parameters": {"path": "lib/foo.ex",}}</action>)
      result = Parser.parse_response(response)
      # Jason rejects trailing commas — should attempt repair
      case result do
        {:ok, r} -> assert r["tool"] == "read_file"
        {:error, _} -> :ok
      end
    end

    test "unescaped newline inside JSON string value" do
      # Models sometimes put literal newlines inside JSON strings
      response = "<action>{\"tool\": \"respond\", \"parameters\": {\"message\": \"line1\nline2\"}}</action>"
      result = Parser.parse_response(response)
      # Should repair by extracting tool name even if JSON is broken
      case result do
        {:ok, r} -> assert r["tool"] == "respond"
        {:error, _} -> :ok
      end
    end

    test "completely empty action tag" do
      response = "<action></action>"
      assert {:error, _} = Parser.parse_response(response)
    end

    test "whitespace-only action tag" do
      response = "<action>   \n   </action>"
      assert {:error, _} = Parser.parse_response(response)
    end

    test "action tag with just the word null" do
      response = "<action>null</action>"
      assert {:error, _} = Parser.parse_response(response)
    end

    test "action tag with JSON array instead of object" do
      response = ~s(<action>[{"tool": "read_file"}]</action>)
      assert {:error, _} = Parser.parse_response(response)
    end

    test "deeply nested JSON (50 levels)" do
      inner = Enum.reduce(1..50, ~s("deep"), fn _, acc -> ~s({"n": #{acc}}) end)
      response = ~s(<action>{"tool": "think", "parameters": {"thought": #{inner}}}</action>)
      result = Parser.parse_response(response)
      assert {:ok, r} = result
      assert r["tool"] == "think"
    end

    test "JSON with BOM (byte order mark)" do
      bom = <<0xEF, 0xBB, 0xBF>>
      response = "<action>" <> bom <> ~s({"tool": "think", "parameters": {}}) <> "</action>"
      # BOM before JSON may cause decode failure — should handle
      result = Parser.parse_response(response)
      case result do
        {:ok, r} -> assert r["tool"] == "think"
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 2. Injection attempts in tool names and parameters
  # ============================================================================

  describe "injection attempts" do
    test "path traversal in tool parameters" do
      response = ~s(<action>{"tool": "read_file", "parameters": {"path": "../../../../etc/passwd"}}</action>)
      # Parser should parse it — sandbox enforcement is a separate layer
      {:ok, result} = Parser.parse_response(response)
      assert result["parameters"]["path"] == "../../../../etc/passwd"
    end

    test "tool name with special characters" do
      response = ~s(<action>{"tool": "../read_file", "parameters": {}}</action>)
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "../read_file"
    end

    test "script injection in parameter value" do
      response = ~s[<action>{"tool": "respond", "parameters": {"message": "<script>alert('xss')</script>"}}</action>]
      {:ok, result} = Parser.parse_response(response)
      assert result["parameters"]["message"] =~ "<script>"
    end

    test "null bytes in parameter value" do
      response = ~s(<action>{"tool": "read_file", "parameters": {"path": "lib/foo\\u0000.ex"}}</action>)
      {:ok, result} = Parser.parse_response(response)
      assert result["parameters"]["path"] =~ "foo"
    end

    test "extremely long tool name - ten thousand chars" do
      long_name = String.duplicate("a", 10_000)
      response = ~s(<action>{"tool": "#{long_name}", "parameters": {}}</action>)
      {:ok, result} = Parser.parse_response(response)
      assert String.length(result["tool"]) == 10_000
    end

    test "extremely long parameter value - hundred thousand chars" do
      long_value = String.duplicate("x", 100_000)
      response = ~s(<action>{"tool": "respond", "parameters": {"message": "#{long_value}"}}</action>)
      {:ok, result} = Parser.parse_response(response)
      assert String.length(result["parameters"]["message"]) == 100_000
    end
  end

  # ============================================================================
  # 3. Truncated/partial responses (connection drop)
  # ============================================================================

  describe "truncated responses" do
    test "response cut mid-JSON" do
      response = ~s(<action>{"tool": "read_file", "parameters": {"pa)
      result = Parser.parse_response(response)
      # Should repair or fail — not crash
      case result do
        {:ok, r} -> assert r["tool"] == "read_file"
        {:error, _} -> :ok
      end
    end

    test "response cut mid-tag" do
      response = "<action>{\"tool\": \"think\"}</"
      result = Parser.parse_response(response)
      case result do
        {:ok, r} -> assert r["tool"] == "think"
        {:error, _} -> :ok
      end
    end

    test "response cut after opening action tag" do
      response = "<action>"
      result = Parser.parse_response(response)
      assert {:error, _} = result
    end

    test "response is just an opening brace" do
      response = "{"
      result = Parser.parse_response(response)
      # try_repair_json adds closing brace → "{}" which is valid JSON but no tool key
      assert {:error, _} = result
    end

    test "response cut after tool name, before parameters" do
      response = ~s(<action>{"tool": "read_file")
      result = Parser.parse_response(response)
      # Repair should extract tool name
      case result do
        {:ok, r} -> assert r["tool"] == "read_file"
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 4. Code extraction edge cases
  # ============================================================================

  describe "code extraction edge cases" do
    test "fenced code block containing backticks in code" do
      # Code that contains ``` (e.g., generating markdown or regex)
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"doc","arity":0}}</action>

      ```elixir
      def doc do
        ~s(```elixir
        example code
        ```)
      end
      ```
      """

      result = Parser.parse_response(response)
      # The greedy regex should handle inner backticks
      case result do
        {:ok, r} ->
          assert r["tool"] == "patch_function"
          # Code should be extracted (may or may not include inner backticks)
        {:error, _} ->
          :ok
      end
    end

    test "code block with wrong language tag" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>

      ```python
      def bar do
        :ok
      end
      ```
      """

      # extract_trailing_code handles ```elixir and plain ``` — python should fall to raw extraction
      result = Parser.parse_response(response)
      case result do
        {:ok, r} -> assert r["tool"] == "patch_function"
        {:error, _} -> :ok
      end
    end

    test "empty fenced code block" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>

      ```elixir
      ```
      """

      {:ok, result} = Parser.parse_response(response)
      # Empty code block → no code injected (< 5 chars)
      assert result["tool"] == "patch_function"
    end

    test "trailing code that is not Elixir (plain text explanation)" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo","function":"bar","arity":0}}</action>

      Here's what I changed: I updated the function to handle the new edge case
      by adding a guard clause. The function now checks if the input is valid
      before processing.
      """

      {:ok, result} = Parser.parse_response(response)
      # No code injection — text doesn't start with def/defp/@
      assert result["tool"] == "patch_function"
      refute Map.has_key?(result["parameters"], "code")
    end

    test "payload tag with only whitespace" do
      response = """
      <action>{"tool":"patch_function","parameters":{"module":"Foo"}}</action>
      <payload>

      </payload>
      """

      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "patch_function"
    end
  end

  # ============================================================================
  # 5. Multi-action adversarial cases
  # ============================================================================

  describe "multi-action edge cases" do
    test "one valid and one invalid action" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"a.ex"}}</action>
      <action>NOT JSON AT ALL</action>
      """

      {:ok, actions} = Parser.parse_all_actions(response)
      # First is valid, second is nil (filtered out)
      valid = Enum.filter(actions, & &1 != nil)
      assert length(valid) >= 1
      assert hd(valid)["tool"] == "read_file"
    end

    test "10 action blocks" do
      blocks = for i <- 1..10 do
        ~s(<action>{"tool":"read_file","parameters":{"path":"file_#{i}.ex"}}</action>)
      end
      response = Enum.join(blocks, "\n")

      {:ok, actions} = Parser.parse_all_actions(response)
      assert length(actions) == 10
    end

    test "no closing tags on any action" do
      response = """
      <action>{"tool":"read_file","parameters":{"path":"a.ex"}}
      <action>{"tool":"read_file","parameters":{"path":"b.ex"}}
      """

      # parse_all_actions uses regex that requires </action> — should find nothing
      result = Parser.parse_all_actions(response)
      assert {:error, :no_actions_found} = result
    end

    test "nested action tags (action inside action)" do
      response = """
      <action>{"tool":"respond","parameters":{"message":"<action>inner</action>"}}</action>
      """

      # The greedy regex will match the first <action> to the first </action>
      # which is inside the string value — this tests regex robustness
      result = Parser.parse_response(response)
      # Non-greedy (.*?) should match to the first </action>
      # The JSON contains literal <action> in the message — may break regex
      case result do
        {:ok, r} -> assert r["tool"] == "respond"
        {:error, _} -> :ok  # acceptable — nested tags are pathological
      end
    end
  end

  # ============================================================================
  # 6. Plain JSON adversarial cases (Tier 4)
  # ============================================================================

  describe "plain JSON adversarial" do
    test "JSON buried in long prose (model explaining before answering)" do
      prose = String.duplicate("I think we should consider the implications. ", 50)
      response = prose <> ~s({"tool":"think","parameters":{"thought":"analyzing"}})
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
    end

    test "multiple JSON objects in response (first wins)" do
      response = ~s({"tool":"think","parameters":{}} and also {"tool":"respond","parameters":{"message":"hi"}})
      {:ok, result} = Parser.parse_response(response)
      # find_json_bounds finds first { and matches to its closing }
      assert result["tool"] == "think"
    end

    test "JSON with unicode keys" do
      response = ~s({"tool":"respond","parameters":{"méssage":"héllo"}})
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "respond"
    end

    test "JSON with numeric string that looks like a number" do
      response = ~s({"tool":"read_file","parameters":{"path":"123"}})
      {:ok, result} = Parser.parse_response(response)
      assert result["parameters"]["path"] == "123"
    end

    test "empty string" do
      assert {:error, _} = Parser.parse_response("")
    end

    test "just whitespace" do
      assert {:error, _} = Parser.parse_response("   \n\t  ")
    end

    test "just a number" do
      assert {:error, _} = Parser.parse_response("42")
    end

    test "just a boolean" do
      assert {:error, _} = Parser.parse_response("true")
    end

    test "JSON object with no tool key" do
      response = ~s({"action": "read_file", "params": {"path": "foo.ex"}})
      assert {:error, :invalid_tool_format} = Parser.parse_response(response)
    end
  end

  # ============================================================================
  # 7. JSON repair edge cases
  # ============================================================================

  describe "JSON repair edge cases" do
    test "repairs 1 missing closing brace" do
      response = ~s({"tool": "think", "parameters": {"thought": "hello"})
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
    end

    test "repairs 3 missing closing braces" do
      response = ~s({"tool": "think", "parameters": {"thought": {"deep": {"value": "x")
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
    end

    test "action tag with missing closing brace in JSON" do
      response = ~s(<action>{"tool": "read_file", "parameters": {"path": "foo.ex"}</action>)
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
    end

    test "repair does not add braces when balanced" do
      response = ~s({"tool": "think", "parameters": {}})
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
      assert result["parameters"] == %{}
    end

    test "braces inside string values don't confuse repair" do
      response = ~s({"tool": "respond", "parameters": {"message": "use {x} and {y}")
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "respond"
    end
  end

  # ============================================================================
  # 8. Model output patterns seen in production
  # ============================================================================

  describe "real-world model output patterns" do
    test "model prefixes with 'I'll' before action" do
      response = """
      I'll read the file to understand the current implementation.

      <action>{"tool":"read_file","parameters":{"path":"lib/giulia.ex"}}</action>
      """

      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "read_file"
    end

    test "model adds explanation after action" do
      response = """
      <action>{"tool":"respond","parameters":{"message":"Done!"}}</action>

      I've completed the task. Let me know if you need anything else.
      """

      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "respond"
      assert result["parameters"]["message"] == "Done!"
    end

    test "model wraps action in markdown" do
      response = """
      Here's my tool call:

      ```
      <action>{"tool":"think","parameters":{"thought":"analyzing"}}</action>
      ```
      """

      # The <action> is inside a markdown block — parser should still find it
      result = Parser.parse_response(response)
      case result do
        {:ok, r} -> assert r["tool"] == "think"
        {:error, _} -> :ok
      end
    end

    test "model outputs JSON without quotes on tool name (rare)" do
      response = ~s(<action>{tool: "read_file", parameters: {path: "foo.ex"}}</action>)
      # This is not valid JSON at all — should attempt repair
      result = Parser.parse_response(response)
      case result do
        {:ok, r} -> assert r["tool"] == "read_file"
        {:error, _} -> :ok  # acceptable
      end
    end

    test "model outputs tool call then immediately another" do
      response = ~s({"tool":"think","parameters":{}}{"tool":"respond","parameters":{"message":"done"}})
      # Two JSON objects concatenated — parser finds first
      {:ok, result} = Parser.parse_response(response)
      assert result["tool"] == "think"
    end
  end
end
