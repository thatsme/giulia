defmodule Giulia.Inference.TraceTest do
  @moduledoc """
  Tests for Inference.Trace — Agent-based trace storage.

  Tests cover store/get_last lifecycle and the pure from_orchestrator_state/1
  builder function.
  """
  use ExUnit.Case, async: false

  alias Giulia.Inference.Trace
  alias Giulia.Inference.State

  setup do
    case Process.whereis(Trace) do
      nil -> start_supervised!(Trace)
      _pid -> :ok
    end

    # Clear any previous trace
    Agent.update(Trace, fn _ -> nil end)
    :ok
  end

  # ============================================================================
  # store/1 and get_last/0
  # ============================================================================

  describe "store/1 and get_last/0" do
    test "initially returns nil" do
      assert is_nil(Trace.get_last())
    end

    test "stores a trace and retrieves it" do
      trace = %{task: "test task", status: "completed", iteration: 5}
      Trace.store(trace)

      result = Trace.get_last()
      assert result.task == "test task"
      assert result.status == "completed"
      assert result.iteration == 5
    end

    test "adds stored_at timestamp" do
      Trace.store(%{task: "test"})
      result = Trace.get_last()
      assert %DateTime{} = result.stored_at
    end

    test "overwrites previous trace" do
      Trace.store(%{task: "first"})
      Trace.store(%{task: "second"})
      assert Trace.get_last().task == "second"
    end
  end

  # ============================================================================
  # from_orchestrator_state/1
  # ============================================================================

  describe "from_orchestrator_state/1" do
    test "builds trace from state struct" do
      state = State.new(
        task: "fix bug",
        project_path: "/proj/test"
      )

      trace = Trace.from_orchestrator_state(state)

      assert trace.task == "fix bug"
      assert trace.project_path == "/proj/test"
      assert trace.status == "idle"
      assert trace.iteration == 0
      assert trace.max_iterations == 50
      assert trace.consecutive_failures == 0
      assert is_nil(trace.provider)
      assert trace.action_history == []
      assert trace.recent_errors == []
      assert is_nil(trace.last_action)
      assert is_nil(trace.final_response)
    end

    test "formats action history entries" do
      state = %{State.new() |
        action_history: [
          {"read_file", %{"path" => "lib/foo.ex"}, {:ok, "content"}},
          {"edit_file", %{"file" => "lib/bar.ex"}, {:error, "not found"}}
        ]
      }

      trace = Trace.from_orchestrator_state(state)
      assert length(trace.action_history) == 2

      [first, second] = trace.action_history
      assert first.tool == "read_file"
      assert is_map(first.params)
      assert second.tool == "edit_file"
    end

    test "formats last_action tuple" do
      state = %{State.new() | last_action: {"think", %{"thought" => "hmm"}}}
      trace = Trace.from_orchestrator_state(state)
      assert trace.last_action.tool == "think"
    end

    test "handles nil last_action" do
      state = State.new()
      trace = Trace.from_orchestrator_state(state)
      assert is_nil(trace.last_action)
    end

    test "truncates long param values" do
      long_value = String.duplicate("x", 200)
      state = %{State.new() |
        action_history: [{"tool", %{"content" => long_value}, {:ok, "done"}}]
      }

      trace = Trace.from_orchestrator_state(state)
      [entry] = trace.action_history
      assert String.length(entry.params["content"]) <= 104  # 100 + "..."
    end
  end
end
