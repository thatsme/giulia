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

  describe "rebuild_from_registry/1 — restart-time recovery" do
    test "rebuilds ETS rows from live Registry entries with real started_at" do
      tmp =
        Path.join(System.tmp_dir!(), "giulia_test_rebuild_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "GIULIA.md"), "# Test")

      on_exit(fn ->
        ContextManager.shutdown_project(tmp)
        File.rm_rf!(tmp)
      end)

      # Trigger ProjectContext start via the public API (registers in Giulia.Registry).
      assert {:ok, project_pid} = ContextManager.get_context(tmp)
      assert is_pid(project_pid) and Process.alive?(project_pid)

      original_started_at =
        Giulia.Core.ProjectContext.started_at(project_pid)

      assert %DateTime{} = original_started_at

      # Simulate a ContextManager restart: rebuild a private ETS table from
      # the Registry. Production code calls this from init/1; doing it
      # against a fresh table here lets us verify the rebuild is correct
      # without killing the live ContextManager mid-suite.
      table_name = :"rebuild_test_#{System.unique_integer([:positive])}"
      table = :ets.new(table_name, [:named_table, :public, :set])
      on_exit(fn -> if :ets.info(table_name) != :undefined, do: :ets.delete(table) end)

      rebuilt = ContextManager.rebuild_from_registry(table)
      assert rebuilt >= 1

      normalized = String.trim_trailing(tmp, "/")
      assert [{^normalized, ^project_pid, ^original_started_at}] =
               :ets.lookup(table, normalized)
    end
  end

  describe "start_context/2 — supervisor unavailable" do
    test "returns {:error, :supervisor_unavailable} when supervisor is :noproc" do
      # Pass a registered name that is guaranteed not to exist — exercises
      # the :exit, {:noproc, _} catch clause without touching the live
      # ProjectSupervisor (which the rest of the suite depends on).
      dead_supervisor = :"unregistered_#{System.unique_integer([:positive])}"
      assert Process.whereis(dead_supervisor) == nil

      tmp =
        Path.join(System.tmp_dir!(), "giulia_test_supervisor_unavailable_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :supervisor_unavailable} =
               ContextManager.start_context(tmp, dead_supervisor)
    end
  end
end
