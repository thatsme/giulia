defmodule Giulia.Tools.CommitChangesTest do
  @moduledoc """
  Tests for Tools.CommitChanges — pseudo-tool for atomic commit.
  """
  use ExUnit.Case, async: true

  alias Giulia.Tools.CommitChanges

  # ============================================================================
  # Registry Behaviour
  # ============================================================================

  describe "registry behaviour" do
    test "name returns 'commit_changes'" do
      assert "commit_changes" = CommitChanges.name()
    end

    test "description mentions atomic/flush/commit" do
      desc = CommitChanges.description()
      assert is_binary(desc)
      assert String.contains?(desc, "flush") or String.contains?(desc, "commit") or String.contains?(desc, "Atomically")
    end

    test "parameters includes optional message field" do
      params = CommitChanges.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :message)
      assert params.required == []
    end
  end

  # ============================================================================
  # execute/2
  # ============================================================================

  describe "execute/2" do
    test "returns intercepted message with commit message" do
      assert {:ok, msg} = CommitChanges.execute(%{"message" => "fix bug"}, [])
      assert String.contains?(msg, "intercepted")
      assert String.contains?(msg, "fix bug")
    end

    test "returns intercepted message without commit message" do
      assert {:ok, msg} = CommitChanges.execute(%{}, [])
      assert String.contains?(msg, "intercepted")
    end
  end
end
