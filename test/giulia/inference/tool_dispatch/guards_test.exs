defmodule Giulia.Inference.ToolDispatch.GuardsTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.State
  alias Giulia.Inference.ToolDispatch.Guards

  # ============================================================================
  # edit_file_after_patch_failure?/2
  # ============================================================================

  describe "edit_file_after_patch_failure?/2" do
    test "true when edit_file follows failed patch_function" do
      state = %{action_history: [{"patch_function", %{}, {:error, :syntax_error}}]}
      assert Guards.edit_file_after_patch_failure?("edit_file", state)
    end

    test "true when edit_file follows failed write_function" do
      state = %{action_history: [{"write_function", %{}, {:error, :syntax_error}}]}
      assert Guards.edit_file_after_patch_failure?("edit_file", state)
    end

    test "false when last action succeeded" do
      state = %{action_history: [{"patch_function", %{}, {:ok, "done"}}]}
      refute Guards.edit_file_after_patch_failure?("edit_file", state)
    end

    test "false for non-edit_file tools" do
      state = %{action_history: [{"patch_function", %{}, {:error, :syntax_error}}]}
      refute Guards.edit_file_after_patch_failure?("read_file", state)
    end

    test "false with empty history" do
      refute Guards.edit_file_after_patch_failure?("edit_file", %{action_history: []})
    end
  end

  # ============================================================================
  # preflight_check/2
  # ============================================================================

  describe "preflight_check/2" do
    test "returns :ok for patch_function with code" do
      assert :ok = Guards.preflight_check("patch_function", %{"code" => "def foo, do: :ok"})
    end

    test "returns error for patch_function without code" do
      assert {:error, :missing_code} = Guards.preflight_check("patch_function", %{})
    end

    test "returns error for write_function with empty code" do
      assert {:error, :missing_code} = Guards.preflight_check("write_function", %{"code" => "  "})
    end

    test "returns :ok for non-code tools" do
      assert :ok = Guards.preflight_check("read_file", %{})
      assert :ok = Guards.preflight_check("search_code", %{"query" => "test"})
    end
  end

  # ============================================================================
  # requires_approval?/3
  # ============================================================================

  describe "requires_approval?/3" do
    test "write tools require approval" do
      state = State.new()
      assert Guards.requires_approval?("write_file", %{}, state)
      assert Guards.requires_approval?("edit_file", %{}, state)
      assert Guards.requires_approval?("patch_function", %{}, state)
    end

    test "read tools don't require approval" do
      state = State.new()
      refute Guards.requires_approval?("read_file", %{}, state)
      refute Guards.requires_approval?("search_code", %{}, state)
    end

    test "run_tests doesn't require approval" do
      refute Guards.requires_approval?("run_tests", %{}, State.new())
    end

    test "run_mix requires approval for non-safe commands" do
      state = State.new()
      assert Guards.requires_approval?("run_mix", %{"command" => "deps.get"}, state)
    end

    test "run_mix skips approval for compile" do
      refute Guards.requires_approval?("run_mix", %{"command" => "compile"}, State.new())
    end
  end

  # ============================================================================
  # extract_downstream_dependents/1
  # ============================================================================

  describe "extract_downstream_dependents/1" do
    test "extracts module names from impact output" do
      text = """
      UPSTREAM: ...

      DOWNSTREAM (what depends on me):
      - Giulia.Tools.Registry (depth 1)
      - Giulia.Inference.Engine (depth 1)

      FUNCTIONS:
      - foo/1
      """

      result = Guards.extract_downstream_dependents(text)
      assert "Giulia.Tools.Registry" in result
      assert "Giulia.Inference.Engine" in result
      assert length(result) == 2
    end

    test "returns empty for no downstream section" do
      assert Guards.extract_downstream_dependents("no downstream here") == []
    end

    test "filters out empty and none entries" do
      text = """
      DOWNSTREAM (what depends on me):
      - (none — nothing depends on this)
      """

      assert Guards.extract_downstream_dependents(text) == []
    end
  end

  # ============================================================================
  # module_to_path/1
  # ============================================================================

  describe "module_to_path/1" do
    test "converts module name to underscore path" do
      assert Guards.module_to_path("Giulia.Tools.Registry") == "registry"
    end

    test "handles single-segment module" do
      assert Guards.module_to_path("GenServer") == "gen_server"
    end
  end

  # ============================================================================
  # find_last_successful_observation/1
  # ============================================================================

  describe "find_last_successful_observation/1" do
    test "returns longest successful result" do
      state = %{
        action_history: [
          {"read_file", %{}, {:ok, "short"}},
          {"search_code", %{}, {:ok, "this is a much longer result string"}},
          {"list_files", %{}, {:error, :not_found}}
        ]
      }

      result = Guards.find_last_successful_observation(state)
      assert result == "this is a much longer result string"
    end

    test "returns nil when no successful actions" do
      state = %{action_history: [{"read_file", %{}, {:error, :not_found}}]}
      assert Guards.find_last_successful_observation(state) == nil
    end

    test "returns nil for empty history" do
      assert Guards.find_last_successful_observation(%{action_history: []}) == nil
    end
  end
end
