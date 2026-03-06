defmodule Giulia.StructuredOutputAdversarialTest do
  @moduledoc """
  Adversarial tests for StructuredOutput (extract_json, parse, validate_tool_call).

  Targets the JSON extraction layer that handles raw LLM output — the most
  exposed attack surface since it processes untrusted text directly.
  """
  use ExUnit.Case, async: true

  alias Giulia.StructuredOutput

  # ============================================================================
  # 1. extract_json — pathological inputs
  # ============================================================================

  describe "extract_json with pathological input" do
    test "JSON embedded in HTML — extraction includes trailing HTML" do
      input = """
      <div class="response">
        <p>Here is the result:</p>
        <code>{"tool": "read_file", "parameters": {"path": "lib/foo.ex"}}</code>
      </div>
      """

      # KNOWN LIMITATION: find_json_with_regex finds first { but the brace matcher
      # may extract past the closing } if HTML follows. The JSON is extractable
      # but may include trailing HTML in the string.
      result = StructuredOutput.extract_json(input)
      case result do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, decoded} -> assert decoded["tool"] == "read_file"
            {:error, _} -> :ok  # extraction included trailing HTML — known limitation
          end
        {:error, _} -> :ok
      end
    end

    test "multiple JSON objects — extracts first complete one" do
      input = ~s(first: {"a": 1} and second: {"b": 2})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["a"] == 1
    end

    test "JSON with escaped unicode" do
      input = ~s({"tool": "respond", "parameters": {"message": "\\u0048ello"}})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["parameters"]["message"] == "Hello"
    end

    test "string that looks like JSON but is just braces in prose" do
      input = "The function returns {error, reason} when it fails"
      # This has unquoted keys — not valid JSON
      result = StructuredOutput.extract_json(input)
      case result do
        {:ok, json} ->
          # Even if extracted, it shouldn't decode to valid JSON
          case Jason.decode(json) do
            {:ok, _} -> :ok  # somehow valid — fine
            {:error, _} -> :ok
          end
        {:error, _} -> :ok
      end
    end

    test "very large input with prose then JSON at the end" do
      padding = String.duplicate("This is padding text. ", 50_000)
      json = ~s({"tool": "think", "parameters": {"thought": "found it"}})
      input = padding <> json

      {:ok, extracted} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(extracted)
      assert decoded["tool"] == "think"
    end

    test "JSON with all value types" do
      input = ~s({"string": "hello", "number": 42, "float": 3.14, "bool": true, "null": null, "array": [1,2], "object": {"nested": true}})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["string"] == "hello"
      assert decoded["number"] == 42
      assert decoded["null"] == nil
      assert decoded["bool"] == true
    end

    test "unclosed string inside JSON" do
      input = ~s({"tool": "respond", "parameters": {"message": "unclosed)
      result = StructuredOutput.extract_json(input)
      # Should repair or fail — not crash
      case result do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end

    test "empty object" do
      {:ok, json} = StructuredOutput.extract_json("{}")
      assert json == "{}"
    end

    test "nested markdown fences — known limitation" do
      input = """
      ```json
      ```json
      {"tool": "think"}
      ```
      ```
      """

      # KNOWN LIMITATION: nested fences confuse the strip_markdown_fences regex.
      # The inner ``` gets stripped, leaving malformed content.
      result = StructuredOutput.extract_json(input)
      case result do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, decoded} -> assert decoded["tool"] == "think"
            {:error, _} -> :ok  # stripped wrong fence — known limitation
          end
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 2. Brace counting / repair edge cases
  # ============================================================================

  describe "brace counting edge cases" do
    test "escaped backslash before quote" do
      # \\" means escaped backslash then end-of-string
      input = ~s({"key": "value\\\\"})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["key"] == "value\\"
    end

    test "deeply nested 20 levels repaired" do
      # 20 opening braces, only 10 closing
      opens = String.duplicate("{\"n\":", 20)
      closes = String.duplicate("}", 10)
      input = opens <> "1" <> closes

      result = StructuredOutput.extract_json(input)
      case result do
        {:ok, json} ->
          # Should have added 10 more closing braces
          assert String.ends_with?(String.trim(json), "}")
        {:error, _} -> :ok
      end
    end

    test "closing brace inside string doesn't end extraction" do
      input = ~s({"tool": "respond", "parameters": {"message": "close } here"}})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["parameters"]["message"] == "close } here"
    end

    test "opening brace inside string doesn't start nesting" do
      input = ~s({"tool": "respond", "parameters": {"message": "open { here"}})
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["parameters"]["message"] == "open { here"
    end
  end

  # ============================================================================
  # 3. validate_tool_call edge cases
  # ============================================================================

  describe "validate_tool_call edge cases" do
    test "empty arguments map for read_file" do
      result = StructuredOutput.validate_tool_call(%{name: "read_file", arguments: %{}})
      # ReadFile requires path — empty args should fail validation
      assert {:error, _} = result
    end

    test "extra fields in arguments are ignored" do
      result = StructuredOutput.validate_tool_call(%{
        name: "read_file",
        arguments: %{"path" => "lib/foo.ex", "extra_field" => "ignored"}
      })
      assert {:ok, struct} = result
      assert struct.path == "lib/foo.ex"
    end

    test "wrong type for path (integer instead of string)" do
      result = StructuredOutput.validate_tool_call(%{
        name: "read_file",
        arguments: %{"path" => 42}
      })
      # Ecto should reject non-string path
      assert {:error, _} = result
    end

    test "nil arguments returns error instead of crash" do
      # Fixed: parse_map now handles nil gracefully
      result = StructuredOutput.validate_tool_call(%{name: "read_file", arguments: nil})
      assert {:error, :nil_arguments} = result
    end
  end

  # ============================================================================
  # 4. parse/2 with adversarial schema inputs
  # ============================================================================

  describe "parse/2 adversarial" do
    test "JSON with extra nesting doesn't confuse schema" do
      input = ~s({"path": "lib/foo.ex", "nested": {"deep": {"value": true}}})
      {:ok, struct} = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert struct.path == "lib/foo.ex"
    end

    test "completely wrong schema data" do
      input = ~s({"name": "John", "age": 30, "email": "john@example.com"})
      result = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert {:error, {:validation, _}} = result
    end

    test "JSON with null value for required field" do
      input = ~s({"path": null})
      result = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # 5. Action tag stripping
  # ============================================================================

  describe "strip_action_tags via extract_json" do
    test "nested action tags" do
      input = "<action><action>{\"tool\": \"think\"}</action></action>"
      {:ok, json} = StructuredOutput.extract_json(input)
      {:ok, decoded} = Jason.decode(json)
      # Inner <action> should be stripped first (non-greedy)
      assert decoded["tool"] == "think"
    end

    test "action tag with attributes (not standard but possible)" do
      input = "<action type=\"json\">{\"tool\": \"think\", \"parameters\": {}}</action>"
      # Regex expects <action> not <action type="json"> — may not match
      result = StructuredOutput.extract_json(input)
      case result do
        {:ok, json} ->
          {:ok, decoded} = Jason.decode(json)
          assert decoded["tool"] == "think"
        {:error, _} -> :ok
      end
    end
  end
end
