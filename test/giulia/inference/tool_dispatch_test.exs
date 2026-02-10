defmodule Giulia.Inference.ToolDispatchTest do
  @moduledoc """
  Tests for Inference.ToolDispatch — pure helper functions.

  Tests the stateless utility functions: extract_downstream_dependents,
  module_to_path, and find_last_successful_observation. The full
  execute/4 flow requires GenServers (Registry, Events, Approval)
  and is not tested here.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.{ToolDispatch, State}

  # ============================================================================
  # extract_downstream_dependents/1
  # ============================================================================

  describe "extract_downstream_dependents/1" do
    test "extracts module names from downstream section" do
      result_str = """
      MODULE: Giulia.Tools.Registry
      UPSTREAM (what I depend on):
      - Giulia.Context.Store (depth: 1)

      DOWNSTREAM (what depends on me):
      - Giulia.Inference.ToolDispatch (depth: 1)
      - Giulia.Inference.Orchestrator (depth: 1)
      - Giulia.Daemon.Endpoint (depth: 1)

      FUNCTIONS:
      - execute/3
      """

      deps = ToolDispatch.extract_downstream_dependents(result_str)
      assert "Giulia.Inference.ToolDispatch" in deps
      assert "Giulia.Inference.Orchestrator" in deps
      assert "Giulia.Daemon.Endpoint" in deps
      assert length(deps) == 3
    end

    test "returns empty list when no downstream section" do
      result_str = "MODULE: Foo\nSome random output"
      assert [] = ToolDispatch.extract_downstream_dependents(result_str)
    end

    test "returns empty list for '(none)' entries" do
      result_str = """
      DOWNSTREAM (what depends on me):
      - (none — nothing depends on this)
      """

      assert [] = ToolDispatch.extract_downstream_dependents(result_str)
    end

    test "strips depth annotations from module names" do
      result_str = """
      DOWNSTREAM (what depends on me):
      - Alpha (depth: 1)
      - Beta (depth: 2)
      """

      deps = ToolDispatch.extract_downstream_dependents(result_str)
      assert "Alpha" in deps
      assert "Beta" in deps
      # Should not contain "(depth: ...)" in the names
      Enum.each(deps, fn dep ->
        refute String.contains?(dep, "depth")
      end)
    end

    test "stops at FUNCTIONS section" do
      result_str = """
      DOWNSTREAM (what depends on me):
      - Alpha (depth: 1)

      FUNCTIONS:
      - run/1
      - stop/0
      """

      deps = ToolDispatch.extract_downstream_dependents(result_str)
      assert deps == ["Alpha"]
      refute Enum.any?(deps, &String.contains?(&1, "run"))
    end
  end

  # ============================================================================
  # module_to_path/1
  # ============================================================================

  describe "module_to_path/1" do
    test "converts simple module name to snake_case" do
      assert "registry" = ToolDispatch.module_to_path("Registry")
    end

    test "extracts and converts last segment of dotted name" do
      assert "tool_dispatch" = ToolDispatch.module_to_path("Giulia.Inference.ToolDispatch")
    end

    test "handles CamelCase to snake_case" do
      assert "context_builder" = ToolDispatch.module_to_path("Giulia.Inference.ContextBuilder")
    end

    test "handles single-word module" do
      assert "foo" = ToolDispatch.module_to_path("Foo")
    end

    test "handles deeply nested module" do
      assert "deep" = ToolDispatch.module_to_path("A.B.C.D.Deep")
    end
  end

  # ============================================================================
  # find_last_successful_observation/1
  # ============================================================================

  describe "find_last_successful_observation/1" do
    test "finds longest successful observation" do
      state = %{State.new() |
        action_history: [
          {"read_file", %{}, {:ok, "short"}},
          {"search_code", %{}, {:ok, "this is a much longer result with more content"}},
          {"list_files", %{}, {:error, "failed"}}
        ]
      }

      result = ToolDispatch.find_last_successful_observation(state)
      assert result == "this is a much longer result with more content"
    end

    test "returns nil when no successful observations" do
      state = %{State.new() |
        action_history: [
          {"read_file", %{}, {:error, "not found"}},
          {"edit_file", %{}, {:error, "failed"}}
        ]
      }

      assert is_nil(ToolDispatch.find_last_successful_observation(state))
    end

    test "returns nil for empty history" do
      state = State.new()
      assert is_nil(ToolDispatch.find_last_successful_observation(state))
    end

    test "skips empty string results" do
      state = %{State.new() |
        action_history: [
          {"think", %{}, {:ok, ""}},
          {"read_file", %{}, {:ok, "actual content"}}
        ]
      }

      result = ToolDispatch.find_last_successful_observation(state)
      assert result == "actual content"
    end

    test "skips non-binary ok results" do
      state = %{State.new() |
        action_history: [
          {"tool", %{}, {:ok, 42}},
          {"read_file", %{}, {:ok, "text content"}}
        ]
      }

      result = ToolDispatch.find_last_successful_observation(state)
      assert result == "text content"
    end
  end
end
