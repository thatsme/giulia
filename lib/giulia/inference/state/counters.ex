defmodule Giulia.Inference.State.Counters do
  @moduledoc """
  Counter arithmetic for the Orchestrator state.

  All functions operate on the `state.counters` sub-map:
  iteration tracking, failure counting, repeat detection, and goal blocks.

  Extracted from `Giulia.Inference.State` (Build 110).
  """

  # Note: uses map() instead of state() to avoid circular dependency
  # (State delegates to Counters, Counters would reference state())
  @type state :: map()

  # ============================================================================
  # Mutators
  # ============================================================================

  @spec increment_iteration(state()) :: state()
  def increment_iteration(state) do
    put_in(state.counters.iteration, state.counters.iteration + 1)
  end

  @spec increment_failures(state()) :: state()
  def increment_failures(state) do
    put_in(state.counters.consecutive_failures, state.counters.consecutive_failures + 1)
  end

  @spec reset_failures(state()) :: state()
  def reset_failures(state) do
    put_in(state.counters.consecutive_failures, 0)
  end

  @spec increment_syntax_failures(state()) :: state()
  def increment_syntax_failures(state) do
    put_in(state.counters.syntax_failures, state.counters.syntax_failures + 1)
  end

  @spec set_syntax_failures(state(), non_neg_integer()) :: state()
  def set_syntax_failures(state, n) do
    put_in(state.counters.syntax_failures, n)
  end

  @spec increment_repeat(state()) :: state()
  def increment_repeat(state) do
    put_in(state.counters.repeat_count, state.counters.repeat_count + 1)
  end

  @spec reset_repeat(state()) :: state()
  def reset_repeat(state) do
    put_in(state.counters.repeat_count, 0)
  end

  @spec increment_goal_blocks(state()) :: state()
  def increment_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, state.counters.goal_tracker_blocks + 1)
  end

  @spec reset_goal_blocks(state()) :: state()
  def reset_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, 0)
  end

  @spec set_max_iterations(state(), pos_integer()) :: state()
  def set_max_iterations(state, n) do
    put_in(state.counters.max_iterations, n)
  end

  @spec bump_max_iterations(state(), pos_integer()) :: state()
  def bump_max_iterations(state, bonus) do
    put_in(state.counters.max_iterations, state.counters.max_iterations + bonus)
  end

  # ============================================================================
  # Predicates
  # ============================================================================

  @spec max_iterations?(state()) :: boolean()
  def max_iterations?(state) do
    state.counters.iteration >= state.counters.max_iterations
  end

  @spec max_failures?(state()) :: boolean()
  def max_failures?(state) do
    state.counters.consecutive_failures >= state.counters.max_failures
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @spec iteration(state()) :: non_neg_integer()
  def iteration(state), do: state.counters.iteration

  @spec max_iterations(state()) :: pos_integer()
  def max_iterations(state), do: state.counters.max_iterations

  @spec consecutive_failures(state()) :: non_neg_integer()
  def consecutive_failures(state), do: state.counters.consecutive_failures

  @spec max_failures(state()) :: pos_integer()
  def max_failures(state), do: state.counters.max_failures

  @spec repeat_count(state()) :: non_neg_integer()
  def repeat_count(state), do: state.counters.repeat_count

  @spec syntax_failures(state()) :: non_neg_integer()
  def syntax_failures(state), do: state.counters.syntax_failures

  @spec goal_tracker_blocks(state()) :: non_neg_integer()
  def goal_tracker_blocks(state), do: state.counters.goal_tracker_blocks
end
