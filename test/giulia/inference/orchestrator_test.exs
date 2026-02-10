defmodule Giulia.Inference.OrchestratorTest do
  @moduledoc """
  Tests for Inference.Orchestrator — thin GenServer shell.

  Tests the GenServer lifecycle (init, get_state, cancel, pause).
  Does NOT test execute/2 which requires Engine + providers.
  """
  use ExUnit.Case, async: false

  alias Giulia.Inference.{Orchestrator, State}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp start_orchestrator(opts \\ []) do
    default_opts = [project_path: "/test/orch_project"]
    {:ok, pid} = Orchestrator.start_link(Keyword.merge(default_opts, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000) end)
    pid
  end

  # ============================================================================
  # init/1
  # ============================================================================

  describe "init/1" do
    test "starts successfully with project_path" do
      pid = start_orchestrator()
      assert Process.alive?(pid)
    end

    test "initializes with idle status" do
      pid = start_orchestrator()
      state = Orchestrator.get_state(pid)
      assert state.status == :idle
    end

    test "initializes with nil task" do
      pid = start_orchestrator()
      state = Orchestrator.get_state(pid)
      assert state.task == nil
    end

    test "initializes with project_path from opts" do
      pid = start_orchestrator(project_path: "/my/project")
      state = Orchestrator.get_state(pid)
      assert state.project_path == "/my/project"
    end

    test "initializes transaction from opts" do
      pid = start_orchestrator()
      state = Orchestrator.get_state(pid)
      assert %Giulia.Inference.Transaction{} = state.transaction
    end
  end

  # ============================================================================
  # get_state/1
  # ============================================================================

  describe "get_state/1" do
    test "returns State struct" do
      pid = start_orchestrator()
      state = Orchestrator.get_state(pid)
      assert %State{} = state
    end

    test "state has expected fields" do
      pid = start_orchestrator()
      state = Orchestrator.get_state(pid)
      assert Map.has_key?(state, :status)
      assert Map.has_key?(state, :task)
      assert Map.has_key?(state, :messages)
      assert Map.has_key?(state, :project_path)
    end
  end

  # ============================================================================
  # cancel/1
  # ============================================================================

  describe "cancel/1" do
    test "cancel on idle orchestrator does not crash" do
      pid = start_orchestrator()
      Orchestrator.cancel(pid)
      # Give the cast time to process
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # pause/1
  # ============================================================================

  describe "pause/1" do
    test "pause on idle orchestrator does not crash" do
      pid = start_orchestrator()
      Orchestrator.pause(pid)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Public API exports
  # ============================================================================

  describe "public API" do
    setup do
      Code.ensure_loaded!(Orchestrator)
      :ok
    end

    test "exports execute/2 and execute/3" do
      assert function_exported?(Orchestrator, :execute, 2)
      assert function_exported?(Orchestrator, :execute, 3)
    end

    test "exports execute_async/2 and execute_async/3" do
      assert function_exported?(Orchestrator, :execute_async, 2)
      assert function_exported?(Orchestrator, :execute_async, 3)
    end

    test "exports get_state/1" do
      assert function_exported?(Orchestrator, :get_state, 1)
    end

    test "exports cancel/1" do
      assert function_exported?(Orchestrator, :cancel, 1)
    end

    test "exports pause/1" do
      assert function_exported?(Orchestrator, :pause, 1)
    end
  end
end
