defmodule Giulia.Inference.State.CountersTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.State
  alias Giulia.Inference.State.Counters

  setup do
    %{state: State.new()}
  end

  # ============================================================================
  # Iteration
  # ============================================================================

  describe "increment_iteration/1" do
    test "increments iteration by 1", %{state: state} do
      assert Counters.iteration(state) == 0
      state = Counters.increment_iteration(state)
      assert Counters.iteration(state) == 1
      state = Counters.increment_iteration(state)
      assert Counters.iteration(state) == 2
    end
  end

  # ============================================================================
  # Failures
  # ============================================================================

  describe "failures" do
    test "increment and reset", %{state: state} do
      state = Counters.increment_failures(state)
      assert Counters.consecutive_failures(state) == 1

      state = Counters.increment_failures(state)
      assert Counters.consecutive_failures(state) == 2

      state = Counters.reset_failures(state)
      assert Counters.consecutive_failures(state) == 0
    end
  end

  describe "syntax_failures" do
    test "increment and set", %{state: state} do
      state = Counters.increment_syntax_failures(state)
      assert Counters.syntax_failures(state) == 1

      state = Counters.set_syntax_failures(state, 5)
      assert Counters.syntax_failures(state) == 5
    end
  end

  # ============================================================================
  # Repeat
  # ============================================================================

  describe "repeat" do
    test "increment and reset", %{state: state} do
      state = Counters.increment_repeat(state)
      assert Counters.repeat_count(state) == 1

      state = Counters.reset_repeat(state)
      assert Counters.repeat_count(state) == 0
    end
  end

  # ============================================================================
  # Goal blocks
  # ============================================================================

  describe "goal_blocks" do
    test "increment and reset", %{state: state} do
      state = Counters.increment_goal_blocks(state)
      assert Counters.goal_tracker_blocks(state) == 1

      state = Counters.reset_goal_blocks(state)
      assert Counters.goal_tracker_blocks(state) == 0
    end
  end

  # ============================================================================
  # Max iterations
  # ============================================================================

  describe "max_iterations" do
    test "set and bump", %{state: state} do
      state = Counters.set_max_iterations(state, 10)
      assert Counters.max_iterations(state) == 10

      state = Counters.bump_max_iterations(state, 5)
      assert Counters.max_iterations(state) == 15
    end
  end

  # ============================================================================
  # Predicates
  # ============================================================================

  describe "max_iterations?/1" do
    test "false when under limit", %{state: state} do
      refute Counters.max_iterations?(state)
    end

    test "true when at limit" do
      state = State.new(max_iterations: 2)
      state = Counters.increment_iteration(state)
      state = Counters.increment_iteration(state)
      assert Counters.max_iterations?(state)
    end
  end

  describe "max_failures?/1" do
    test "false when under limit", %{state: state} do
      refute Counters.max_failures?(state)
    end

    test "true when at limit" do
      state = State.new()
      # default max_failures is 3
      state = state |> Counters.increment_failures() |> Counters.increment_failures() |> Counters.increment_failures()
      assert Counters.max_failures?(state)
    end
  end
end
