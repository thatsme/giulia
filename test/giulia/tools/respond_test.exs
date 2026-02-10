defmodule Giulia.Tools.RespondTest do
  @moduledoc """
  Tests for Tools.Respond — pseudo-tool for final response.
  """
  use ExUnit.Case, async: true

  alias Giulia.Tools.Respond

  # ============================================================================
  # Registry Behaviour
  # ============================================================================

  describe "registry behaviour" do
    test "name returns 'respond'" do
      assert "respond" = Respond.name()
    end

    test "description is a non-empty string" do
      desc = Respond.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters has message as required" do
      params = Respond.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :message)
      assert "message" in params.required
    end
  end

  # ============================================================================
  # execute/2
  # ============================================================================

  describe "execute/2" do
    test "returns the message directly" do
      assert {:ok, "Hello, user!"} = Respond.execute(%{"message" => "Hello, user!"}, [])
    end

    test "handles empty message" do
      assert {:ok, ""} = Respond.execute(%{"message" => ""}, [])
    end

    test "returns error for missing message parameter" do
      assert {:error, :invalid_parameters} = Respond.execute(%{}, [])
    end

    test "returns error for nil params" do
      assert {:error, :invalid_parameters} = Respond.execute(nil, [])
    end
  end
end
