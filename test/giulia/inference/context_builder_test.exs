defmodule Giulia.Inference.ContextBuilderTest do
  @moduledoc """
  Tests for Inference.ContextBuilder — pure helper functions.

  Tests the stateless utility functions that don't require GenServer
  or Store access: format_params_brief, sanitize_params_for_broadcast,
  count_recent_thinks, resolve_module_from_params dispatch,
  build_readonly_intervention, build_write_intervention.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.{ContextBuilder, State}

  # ============================================================================
  # format_params_brief/1
  # ============================================================================

  describe "format_params_brief/1" do
    test "formats map with string keys" do
      result = ContextBuilder.format_params_brief(%{"path" => "lib/foo.ex", "content" => "hello"})
      assert is_binary(result)
      assert String.contains?(result, "path")
    end

    test "truncates long values to 20 chars" do
      long_val = String.duplicate("x", 100)
      result = ContextBuilder.format_params_brief(%{"content" => long_val})
      assert String.length(result) < 100
    end

    test "takes only first 2 params" do
      params = %{"a" => "1", "b" => "2", "c" => "3", "d" => "4"}
      result = ContextBuilder.format_params_brief(params)
      # Should have at most 2 key-value pairs
      parts = String.split(result, ", ")
      assert length(parts) <= 2
    end

    test "handles non-string values" do
      result = ContextBuilder.format_params_brief(%{"arity" => 2, "module" => :Foo})
      assert is_binary(result)
    end

    test "handles empty map" do
      assert "" = ContextBuilder.format_params_brief(%{})
    end
  end

  # ============================================================================
  # sanitize_params_for_broadcast/1
  # ============================================================================

  describe "sanitize_params_for_broadcast/1" do
    test "truncates large string values" do
      large_content = String.duplicate("x", 1000)
      result = ContextBuilder.sanitize_params_for_broadcast(%{"content" => large_content})
      assert String.length(result["content"]) < 600
      assert String.contains?(result["content"], "truncated")
    end

    test "preserves short string values" do
      result = ContextBuilder.sanitize_params_for_broadcast(%{"path" => "lib/foo.ex"})
      assert result["path"] == "lib/foo.ex"
    end

    test "preserves non-string values" do
      result = ContextBuilder.sanitize_params_for_broadcast(%{"arity" => 2})
      assert result["arity"] == 2
    end

    test "handles non-map input" do
      assert "raw" = ContextBuilder.sanitize_params_for_broadcast("raw")
    end
  end

  # ============================================================================
  # count_recent_thinks/1
  # ============================================================================

  describe "count_recent_thinks/1" do
    test "counts consecutive think calls at start of history" do
      history = [
        {"think", %{}, {:ok, "thought"}},
        {"think", %{}, {:ok, "another thought"}},
        {"read_file", %{}, {:ok, "content"}}
      ]

      assert 2 = ContextBuilder.count_recent_thinks(history)
    end

    test "stops counting at first non-think" do
      history = [
        {"think", %{}, {:ok, "thought"}},
        {"read_file", %{}, {:ok, "content"}},
        {"think", %{}, {:ok, "thought"}}
      ]

      assert 1 = ContextBuilder.count_recent_thinks(history)
    end

    test "returns 0 for empty history" do
      assert 0 = ContextBuilder.count_recent_thinks([])
    end

    test "returns 0 when first action is not think" do
      history = [{"read_file", %{}, {:ok, "content"}}]
      assert 0 = ContextBuilder.count_recent_thinks(history)
    end
  end

  # ============================================================================
  # resolve_module_from_params/3
  # ============================================================================

  describe "resolve_module_from_params/3" do
    test "patch_function returns module directly" do
      result = ContextBuilder.resolve_module_from_params(
        "patch_function", %{"module" => "Giulia.Tools.Registry"}, "/proj"
      )
      assert result == "Giulia.Tools.Registry"
    end

    test "write_function returns module directly" do
      result = ContextBuilder.resolve_module_from_params(
        "write_function", %{module: "Foo.Bar"}, "/proj"
      )
      assert result == "Foo.Bar"
    end

    test "unknown tool returns nil" do
      result = ContextBuilder.resolve_module_from_params(
        "read_file", %{"path" => "lib/foo.ex"}, "/proj"
      )
      assert is_nil(result)
    end
  end

  # ============================================================================
  # build_readonly_intervention/2
  # ============================================================================

  describe "build_readonly_intervention/2" do
    test "includes tool name in intervention" do
      state = %{State.new() |
        action_history: [{"read_file", %{"path" => "lib/foo.ex"}, {:ok, "content"}}],
        counters: %{State.new().counters | repeat_count: 3}
      }

      result = ContextBuilder.build_readonly_intervention("read_file", state)
      assert String.contains?(result, "read_file")
      assert String.contains?(result, "REPETITION ERROR")
      assert String.contains?(result, "PROHIBITED")
    end

    test "includes last result excerpt" do
      state = %{State.new() |
        action_history: [{"search_code", %{}, {:ok, "found 5 matches"}}],
        counters: %{State.new().counters | repeat_count: 2}
      }

      result = ContextBuilder.build_readonly_intervention("search_code", state)
      assert String.contains?(result, "found 5 matches")
    end

    test "handles empty action history" do
      state = State.new()
      result = ContextBuilder.build_readonly_intervention("read_file", state)
      assert String.contains?(result, "no result available")
    end
  end

  # ============================================================================
  # build_write_intervention/3
  # ============================================================================

  describe "build_write_intervention/3" do
    test "includes error and action summaries" do
      state = %{State.new() |
        recent_errors: ["syntax error at line 5"],
        action_history: [{"edit_file", %{"file" => "lib/foo.ex"}, {:error, "not found"}}]
      }

      result = ContextBuilder.build_write_intervention(state, nil, nil)
      assert String.contains?(result, "INTERVENTION")
      assert String.contains?(result, "syntax error")
      assert String.contains?(result, "edit_file")
    end

    test "includes fresh content section when provided" do
      state = State.new()
      result = ContextBuilder.build_write_intervention(state, "lib/foo.ex", "defmodule Foo do\nend")
      assert String.contains?(result, "CONTEXT PURGE")
      assert String.contains?(result, "lib/foo.ex")
      assert String.contains?(result, "defmodule Foo")
    end

    test "handles nil target_file and content" do
      state = State.new()
      result = ContextBuilder.build_write_intervention(state, nil, nil)
      assert String.contains?(result, "INTERVENTION")
      refute String.contains?(result, "CONTEXT PURGE")
    end

    test "shows (none) for empty errors" do
      state = State.new()
      result = ContextBuilder.build_write_intervention(state, nil, nil)
      assert String.contains?(result, "(none)")
    end
  end

  # ============================================================================
  # build_tool_opts/1
  # ============================================================================

  describe "build_tool_opts/1" do
    test "includes project_path when present" do
      state = State.new(project_path: "/my/project")
      opts = ContextBuilder.build_tool_opts(state)
      assert Keyword.get(opts, :project_path) == "/my/project"
    end

    test "includes sandbox when project_path present" do
      state = State.new(project_path: "/my/project")
      opts = ContextBuilder.build_tool_opts(state)
      assert Keyword.has_key?(opts, :sandbox)
    end

    test "returns empty opts when no project" do
      state = State.new()
      opts = ContextBuilder.build_tool_opts(state)
      refute Keyword.has_key?(opts, :project_path)
    end
  end

  # ============================================================================
  # get_working_directory/1
  # ============================================================================

  describe "get_working_directory/1" do
    test "returns project_path mapped to host when present" do
      state = State.new(project_path: "/projects/my_app")
      result = ContextBuilder.get_working_directory(state)
      assert is_binary(result)
    end

    test "falls back to cwd when no project_path" do
      state = State.new()
      result = ContextBuilder.get_working_directory(state)
      assert is_binary(result)
    end
  end
end
