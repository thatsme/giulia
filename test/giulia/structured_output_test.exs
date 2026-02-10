defmodule Giulia.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Giulia.StructuredOutput

  # ── extract_json/1 ──────────────────────────────────────────────────

  describe "extract_json/1" do
    test "extracts clean JSON object" do
      input = ~s({"tool": "think", "parameters": {"thought": "analyzing"}})
      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["tool"] == "think"
      assert decoded["parameters"]["thought"] == "analyzing"
    end

    test "extracts JSON from preamble text" do
      input = ~s(Sure! Here's the JSON: {"tool": "respond", "parameters": {"message": "hello"}})
      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["tool"] == "respond"
    end

    test "extracts JSON from markdown code fences" do
      input = """
      ```json
      {"tool": "think", "parameters": {"thought": "step 1"}}
      ```
      """

      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["tool"] == "think"
    end

    test "extracts JSON from <action> tags" do
      input = """
      <action>
      {"tool": "respond", "parameters": {"message": "done"}}
      </action>
      """

      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["tool"] == "respond"
      assert decoded["parameters"]["message"] == "done"
    end

    test "extracts JSON from unclosed <action> tag" do
      input = """
      <action>
      {"tool": "think", "parameters": {"thought": "hmm"}}
      """

      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["tool"] == "think"
    end

    test "repairs unclosed braces" do
      input = ~s({"tool": "think", "parameters": {"thought": "partial")
      assert {:ok, json} = StructuredOutput.extract_json(input)
      # Should have added closing braces
      assert String.ends_with?(json, "}}")
    end

    test "handles escaped quotes in strings" do
      input = ~s({"tool": "respond", "parameters": {"message": "He said \\"hello\\""}})
      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["parameters"]["message"] == ~s(He said "hello")
    end

    test "handles braces inside string values" do
      input = ~s({"tool": "respond", "parameters": {"message": "use {x} pattern"}})
      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["parameters"]["message"] == "use {x} pattern"
    end

    test "returns error when no JSON found" do
      input = "This is just plain text with no JSON at all"
      assert {:error, :no_json_found} = StructuredOutput.extract_json(input)
    end

    test "extracts array JSON" do
      input = ~s([{"name": "read_file"}, {"name": "write_file"}])
      assert {:ok, json} = StructuredOutput.extract_json(input)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_list(decoded)
      assert length(decoded) == 2
    end
  end

  # ── parse/2 ─────────────────────────────────────────────────────────

  describe "parse/2" do
    test "parses valid JSON against schema" do
      input = ~s({"path": "/src/main.ex"})
      assert {:ok, struct} = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert struct.path == "/src/main.ex"
    end

    test "extracts from preamble and validates" do
      input = ~s(Here is the result: {"path": "lib/giulia.ex"})
      assert {:ok, struct} = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert struct.path == "lib/giulia.ex"
    end

    test "returns error for invalid schema data" do
      # ReadFile requires "path" — passing empty object should fail validation
      input = ~s({})
      assert {:error, {:validation, errors}} = StructuredOutput.parse(input, Giulia.Tools.ReadFile)
      assert Map.has_key?(errors, :path)
    end
  end

  # ── parse_map/2 ─────────────────────────────────────────────────────

  describe "parse_map/2" do
    test "validates a correct map" do
      data = %{"path" => "lib/giulia.ex"}
      assert {:ok, struct} = StructuredOutput.parse_map(data, Giulia.Tools.ReadFile)
      assert struct.path == "lib/giulia.ex"
    end

    test "returns error for missing required fields" do
      data = %{"nonexistent" => "value"}
      assert {:error, %Ecto.Changeset{valid?: false}} =
               StructuredOutput.parse_map(data, Giulia.Tools.ReadFile)
    end
  end

  # ── validate_tool_call/1 ────────────────────────────────────────────

  describe "validate_tool_call/1" do
    test "routes read_file to correct schema" do
      tool_call = %{name: "read_file", arguments: %{"path" => "lib/giulia.ex"}}
      assert {:ok, struct} = StructuredOutput.validate_tool_call(tool_call)
      assert struct.path == "lib/giulia.ex"
    end

    test "returns error for unknown tool" do
      tool_call = %{name: "nonexistent_tool", arguments: %{}}
      assert {:error, {:unknown_tool, "nonexistent_tool"}} =
               StructuredOutput.validate_tool_call(tool_call)
    end
  end
end
