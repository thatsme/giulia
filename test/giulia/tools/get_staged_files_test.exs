defmodule Giulia.Tools.GetStagedFilesTest do
  @moduledoc """
  Tests for Tools.GetStagedFiles — pseudo-tool for inspecting staging buffer.
  """
  use ExUnit.Case, async: true

  alias Giulia.Tools.GetStagedFiles

  # ============================================================================
  # Registry Behaviour
  # ============================================================================

  describe "registry behaviour" do
    test "name returns 'get_staged_files'" do
      assert "get_staged_files" = GetStagedFiles.name()
    end

    test "description mentions staging/transaction" do
      desc = GetStagedFiles.description()
      assert is_binary(desc)
      assert String.contains?(desc, "staged") or String.contains?(desc, "transaction")
    end

    test "parameters has no required fields" do
      params = GetStagedFiles.parameters()
      assert params.type == "object"
      assert params.properties == %{}
      assert params.required == []
    end
  end

  # ============================================================================
  # execute/2
  # ============================================================================

  describe "execute/2" do
    test "returns intercepted message (should never be called directly)" do
      assert {:ok, msg} = GetStagedFiles.execute(%{}, [])
      assert String.contains?(msg, "intercepted")
    end
  end
end
