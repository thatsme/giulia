defmodule Giulia.Core.ContextManagerTest do
  @moduledoc """
  Tests for Core.ContextManager — multi-project traffic controller.

  Tests cover: listing projects, initialized? check, path normalization.
  Uses the live GenServer instance (started by application).
  """
  use ExUnit.Case, async: false

  alias Giulia.Core.ContextManager

  describe "list_projects/0" do
    test "returns a list" do
      projects = ContextManager.list_projects()
      assert is_list(projects)
    end

    test "each project entry has expected fields" do
      projects = ContextManager.list_projects()

      for project <- projects do
        assert Map.has_key?(project, :path)
        assert Map.has_key?(project, :pid)
        assert Map.has_key?(project, :alive)
        assert Map.has_key?(project, :started_at)
      end
    end
  end

  describe "initialized?/1" do
    test "returns true for path with GIULIA.md" do
      # Create a temp dir with GIULIA.md for a reliable test
      tmp = Path.join(System.tmp_dir!(), "giulia_test_init_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "GIULIA.md"), "# Test")

      assert ContextManager.initialized?(tmp)

      File.rm_rf!(tmp)
    end

    test "returns false for nonexistent path" do
      refute ContextManager.initialized?("/nonexistent/path/nowhere")
    end
  end

  describe "get_context/1" do
    test "returns {:needs_init, _} for path without GIULIA.md" do
      result = ContextManager.get_context("/tmp/no_project_here_#{System.unique_integer()}")
      assert {:needs_init, _} = result
    end
  end

  describe "shutdown_project/1" do
    test "returns {:error, :not_found} for unknown project" do
      result = ContextManager.shutdown_project("/tmp/not_a_project_#{System.unique_integer()}")
      assert {:error, :not_found} = result
    end
  end
end
