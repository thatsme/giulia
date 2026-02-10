defmodule Giulia.Tools.ThinkTest do
  @moduledoc """
  Tests for Tools.Think — pseudo-tool for model reasoning.
  """
  use ExUnit.Case, async: true

  alias Giulia.Tools.Think

  # ============================================================================
  # Registry Behaviour
  # ============================================================================

  describe "registry behaviour" do
    test "name returns 'think'" do
      assert "think" = Think.name()
    end

    test "description is a non-empty string" do
      desc = Think.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters has thought as required" do
      params = Think.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :thought)
      assert "thought" in params.required
    end
  end

  # ============================================================================
  # execute/2
  # ============================================================================

  describe "execute/2" do
    test "records thought and returns ok" do
      assert {:ok, msg} = Think.execute(%{"thought" => "analyzing the code"}, [])
      assert String.contains?(msg, "Thought recorded")
      assert String.contains?(msg, "analyzing the code")
    end

    test "handles empty thought string" do
      assert {:ok, msg} = Think.execute(%{"thought" => ""}, [])
      assert String.contains?(msg, "Thought recorded")
    end

    test "returns error for missing thought parameter" do
      assert {:error, :invalid_parameters} = Think.execute(%{}, [])
    end

    test "returns error for nil params" do
      assert {:error, :invalid_parameters} = Think.execute(nil, [])
    end
  end
end
