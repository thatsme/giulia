defmodule Giulia.Inference.StateTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.State
  alias Giulia.Inference.Transaction

  # ============================================================================
  # new/1 + reset/1
  # ============================================================================

  describe "new/1" do
    test "creates state with correct defaults" do
      state = State.new()

      assert state.status == :idle
      assert state.task == nil
      assert state.messages == []
      assert state.counters.iteration == 0
      assert state.counters.max_iterations == 50
      assert state.counters.consecutive_failures == 0
      assert state.counters.max_failures == 3
      assert state.counters.repeat_count == 0
      assert state.counters.syntax_failures == 0
      assert state.counters.goal_tracker_blocks == 0
      assert state.provider.name == nil
      assert state.provider.module == nil
      assert state.provider.escalated == false
      assert state.verification.pending == false
      assert state.verification.test_status == :untested
      assert state.verification.baseline == :unknown
      assert state.goal.last_impact_map == nil
      assert state.goal.modified_files == MapSet.new()
      assert state.pending_tool_calls == []
      assert state.pending_approval == nil
    end

    test "accepts keyword opts" do
      state = State.new(task: "hello", project_path: "/tmp/test", max_iterations: 100)

      assert state.task == "hello"
      assert state.project_path == "/tmp/test"
      assert state.counters.max_iterations == 100
    end

    test "accepts transaction opt" do
      tx = Transaction.new(true)
      state = State.new(transaction: tx)

      assert state.transaction.mode == true
    end
  end

  describe "reset/1" do
    test "clears task state but preserves identity" do
      state = State.new(
        project_path: "/tmp/test",
        project_pid: self(),
        task: "do something"
      )

      # Simulate some work
      state = state
        |> State.set_status(:thinking)
        |> State.increment_iteration()
        |> State.increment_failures()
        |> State.push_message(%{role: "user", content: "hello"})
        |> State.set_test_status(:red)
        |> State.track_modified_file("/tmp/test/lib/foo.ex")

      # Reset
      reset = State.reset(state)

      # Identity preserved
      assert reset.project_path == "/tmp/test"
      assert reset.project_pid == self()

      # Task state cleared
      assert reset.task == nil
      assert reset.status == :idle
      assert reset.messages == []
      assert reset.counters.iteration == 0
      assert reset.counters.consecutive_failures == 0
      assert reset.verification.pending == false
      assert reset.verification.test_status == :untested
      assert reset.goal.last_impact_map == nil
      assert reset.goal.modified_files == MapSet.new()
      assert reset.pending_tool_calls == []
    end
  end

  # ============================================================================
  # consecutive_failures
  # ============================================================================

  describe "consecutive_failures" do
    test "starts at 0" do
      state = State.new()
      assert State.consecutive_failures(state) == 0
    end

    test "increments correctly" do
      state = State.new() |> State.increment_failures()
      assert State.consecutive_failures(state) == 1
    end

    test "increments multiple times" do
      state = State.new()
        |> State.increment_failures()
        |> State.increment_failures()
        |> State.increment_failures()

      assert State.consecutive_failures(state) == 3
    end

    test "resets to 0" do
      state = State.new()
        |> State.increment_failures()
        |> State.increment_failures()
        |> State.reset_failures()

      assert State.consecutive_failures(state) == 0
    end

    test "max_failures? triggers at threshold" do
      state = State.new()  # max_failures default is 3
        |> State.increment_failures()
        |> State.increment_failures()
        |> State.increment_failures()

      assert State.max_failures?(state) == true
    end

    test "max_failures? returns false below threshold" do
      state = State.new()
        |> State.increment_failures()
        |> State.increment_failures()

      assert State.max_failures?(state) == false
    end
  end

  # ============================================================================
  # staging_buffer overlay
  # ============================================================================

  describe "staging_buffer overlay" do
    test "transaction starts as default %Transaction{}" do
      state = State.new()
      assert state.transaction == %Transaction{}
      assert state.transaction.mode == false
      assert state.transaction.staging_buffer == %{}
    end

    test "set_transaction embeds a Transaction struct" do
      tx = %Transaction{
        mode: true,
        staging_buffer: %{"/tmp/test/lib/foo.ex" => "defmodule Foo do\nend\n"}
      }

      state = State.new() |> State.set_transaction(tx)

      assert state.transaction.mode == true
      assert map_size(state.transaction.staging_buffer) == 1
    end

    test "staged content is readable through state.transaction.staging_buffer" do
      content = "defmodule Bar do\n  def hello, do: :world\nend\n"

      tx = %Transaction{
        mode: true,
        staging_buffer: %{"/tmp/test/lib/bar.ex" => content}
      }

      state = State.new() |> State.set_transaction(tx)

      assert state.transaction.staging_buffer["/tmp/test/lib/bar.ex"] == content
    end

    test "unstaged files return nil" do
      tx = %Transaction{
        mode: true,
        staging_buffer: %{"/tmp/test/lib/foo.ex" => "content"}
      }

      state = State.new() |> State.set_transaction(tx)

      assert state.transaction.staging_buffer["/tmp/test/lib/nonexistent.ex"] == nil
    end
  end

  # ============================================================================
  # Counter operations
  # ============================================================================

  describe "iteration" do
    test "increments" do
      state = State.new() |> State.increment_iteration()
      assert State.iteration(state) == 1
    end

    test "max_iterations? triggers" do
      state = State.new(max_iterations: 2)
        |> State.increment_iteration()
        |> State.increment_iteration()

      assert State.max_iterations?(state) == true
    end

    test "bump_max_iterations adds to current" do
      state = State.new() |> State.bump_max_iterations(10)
      assert State.max_iterations(state) == 60
    end
  end

  # ============================================================================
  # Provider management
  # ============================================================================

  describe "provider" do
    test "set_provider updates name and module" do
      state = State.new() |> State.set_provider(:lm_studio, Giulia.Provider.LmStudio)

      assert State.provider_name(state) == :lm_studio
      assert State.provider_module(state) == Giulia.Provider.LmStudio
    end

    test "mark_escalated sets escalated flag" do
      state = State.new() |> State.mark_escalated()
      assert State.escalated?(state) == true
    end
  end

  # ============================================================================
  # Goal tracker
  # ============================================================================

  describe "goal tracker" do
    test "track_modified_file adds to set" do
      state = State.new()
        |> State.track_modified_file("/tmp/a.ex")
        |> State.track_modified_file("/tmp/b.ex")
        |> State.track_modified_file("/tmp/a.ex")  # duplicate

      assert MapSet.size(state.goal.modified_files) == 2
    end

    test "goal_coverage calculates correctly" do
      state = State.new()
        |> State.set_impact_map(%{module: "Foo", dependents: ["A", "B", "C", "D"], count: 4})
        |> State.track_modified_file("/tmp/a.ex")
        |> State.track_modified_file("/tmp/b.ex")

      assert State.goal_coverage(state) == 0.5
    end
  end

  # ============================================================================
  # Repeat detection
  # ============================================================================

  describe "repeat detection" do
    test "repeating? detects same action" do
      state = State.new() |> State.push_action({"read_file", %{"path" => "foo.ex"}})

      assert State.repeating?(state, {"read_file", %{"path" => "foo.ex"}}) == true
      assert State.repeating?(state, {"read_file", %{"path" => "bar.ex"}}) == false
    end

    test "stuck_in_loop? with custom threshold" do
      state = State.new()
        |> State.increment_repeat()
        |> State.increment_repeat()

      assert State.stuck_in_loop?(state, 2) == true
      assert State.stuck_in_loop?(state, 3) == false
    end
  end

  # ============================================================================
  # History operations
  # ============================================================================

  describe "history" do
    test "record_action sets last_action and prepends to history" do
      state = State.new()
        |> State.record_action({"read_file", %{"path" => "a.ex"}, {:ok, "content"}})

      assert state.last_action == {"read_file", %{"path" => "a.ex"}}
      assert length(state.action_history) == 1
    end

    test "push_error caps at 10" do
      state = Enum.reduce(1..15, State.new(), fn i, acc ->
        State.push_error(acc, "error #{i}")
      end)

      assert length(state.recent_errors) == 10
    end
  end
end
