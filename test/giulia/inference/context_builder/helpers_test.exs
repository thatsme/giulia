defmodule Giulia.Inference.ContextBuilder.HelpersTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.ContextBuilder.Helpers

  # ============================================================================
  # format_params_brief/1
  # ============================================================================

  describe "format_params_brief/1" do
    test "formats params as key: value pairs" do
      result = Helpers.format_params_brief(%{"path" => "lib/foo.ex", "line" => 42})
      assert result =~ "path: lib/foo.ex"
      assert result =~ "line: 42"
    end

    test "truncates long string values" do
      long = String.duplicate("x", 50)
      result = Helpers.format_params_brief(%{"content" => long})
      assert String.length(result) < String.length(long)
    end

    test "takes at most 2 params" do
      params = %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}
      result = Helpers.format_params_brief(params)
      # Should have at most 1 comma (2 items)
      comma_count = result |> String.graphemes() |> Enum.count(&(&1 == ","))
      assert comma_count <= 1
    end

    test "handles empty map" do
      assert Helpers.format_params_brief(%{}) == ""
    end
  end

  # ============================================================================
  # sanitize_params_for_broadcast/1
  # ============================================================================

  describe "sanitize_params_for_broadcast/1" do
    test "truncates large string values" do
      big = String.duplicate("a", 1000)
      result = Helpers.sanitize_params_for_broadcast(%{"content" => big})
      assert String.length(result["content"]) < 1000
      assert result["content"] =~ "(truncated)"
    end

    test "leaves small values unchanged" do
      params = %{"path" => "lib/foo.ex", "line" => 5}
      result = Helpers.sanitize_params_for_broadcast(params)
      assert result["path"] == "lib/foo.ex"
      assert result["line"] == 5
    end

    test "handles non-map input" do
      assert Helpers.sanitize_params_for_broadcast(:atom) == :atom
      assert Helpers.sanitize_params_for_broadcast(nil) == nil
    end
  end

  # ============================================================================
  # extract_target_file/1
  # ============================================================================

  describe "extract_target_file/1" do
    test "extracts file from task description" do
      state = %{
        task: "Fix the bug in lib/giulia/tools/registry.ex",
        action_history: []
      }

      assert Helpers.extract_target_file(state) == "lib/giulia/tools/registry.ex"
    end

    test "extracts file from action history" do
      state = %{
        task: "Fix the bug",
        action_history: [
          {"read_file", %{"path" => "lib/foo.ex"}, {:ok, "content"}}
        ]
      }

      assert Helpers.extract_target_file(state) == "lib/foo.ex"
    end

    test "prefers task file over action history" do
      state = %{
        task: "Edit test/bar_test.exs",
        action_history: [
          {"read_file", %{"path" => "lib/foo.ex"}, {:ok, "content"}}
        ]
      }

      assert Helpers.extract_target_file(state) == "test/bar_test.exs"
    end

    test "returns nil when no file found" do
      state = %{task: "Do something", action_history: []}
      assert Helpers.extract_target_file(state) == nil
    end

    test "extracts from edit_file action" do
      state = %{
        task: "Fix it",
        action_history: [
          {"edit_file", %{"file" => "lib/baz.ex"}, {:ok, "done"}}
        ]
      }

      assert Helpers.extract_target_file(state) == "lib/baz.ex"
    end
  end

  # ============================================================================
  # build_tool_opts/1
  # ============================================================================

  describe "build_tool_opts/1" do
    test "includes project_path when set" do
      state = %{project_path: "/projects/Giulia", project_pid: nil}
      opts = Helpers.build_tool_opts(state)
      assert Keyword.get(opts, :project_path) == "/projects/Giulia"
    end

    test "includes sandbox when project_path set" do
      state = %{project_path: "/projects/Giulia", project_pid: nil}
      opts = Helpers.build_tool_opts(state)
      assert Keyword.has_key?(opts, :sandbox)
    end

    test "returns empty opts when no project_path" do
      state = %{project_path: nil, project_pid: nil}
      opts = Helpers.build_tool_opts(state)
      assert opts == []
    end
  end

  # ============================================================================
  # get_constitution/1
  # ============================================================================

  describe "get_constitution/1" do
    test "returns nil for nil pid" do
      assert Helpers.get_constitution(nil) == nil
    end
  end
end
