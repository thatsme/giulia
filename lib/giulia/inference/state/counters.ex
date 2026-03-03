defmodule Giulia.Inference.State.Counters do
  @moduledoc """
  Counter arithmetic for the Orchestrator state.

  All functions operate on the `state.counters` sub-map:
  iteration tracking, failure counting, repeat detection, and goal blocks.

  Extracted from `Giulia.Inference.State` (Build 110).
  """

  alias Giulia.Inference.State

  # ============================================================================
  # Mutators
  # ============================================================================

  @spec increment_iteration(State.t()) :: State.t()
  def increment_iteration(state) do
    put_in(state.counters.iteration, state.counters.iteration + 1)
  end

  @spec increment_failures(State.t()) :: State.t()
  def increment_failures(state) do
    put_in(state.counters.consecutive_failures, state.counters.consecutive_failures + 1)
  end

  @spec reset_failures(State.t()) :: State.t()
  def reset_failures(state) do
    put_in(state.counters.consecutive_failures, 0)
  end

  @spec increment_syntax_failures(State.t()) :: State.t()
  def increment_syntax_failures(state) do
    put_in(state.counters.syntax_failures, state.counters.syntax_failures + 1)
  end

  @spec set_syntax_failures(State.t(), non_neg_integer()) :: State.t()
  def set_syntax_failures(state, n) do
    put_in(state.counters.syntax_failures, n)
  end

  @spec increment_repeat(State.t()) :: State.t()
  def increment_repeat(state) do
    put_in(state.counters.repeat_count, state.counters.repeat_count + 1)
  end

  @spec reset_repeat(State.t()) :: State.t()
  def reset_repeat(state) do
    put_in(state.counters.repeat_count, 0)
  end

  @spec increment_goal_blocks(State.t()) :: State.t()
  def increment_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, state.counters.goal_tracker_blocks + 1)
  end

  @spec reset_goal_blocks(State.t()) :: State.t()
  def reset_goal_blocks(state) do
    put_in(state.counters.goal_tracker_blocks, 0)
  end

  @spec set_max_iterations(State.t(), pos_integer()) :: State.t()
  def set_max_iterations(state, n) do
    put_in(state.counters.max_iterations, n)
  end

  @spec bump_max_iterations(State.t(), pos_integer()) :: State.t()
  def bump_max_iterations(state, bonus) do
    put_in(state.counters.max_iterations, state.counters.max_iterations + bonus)
  end

  # ============================================================================
  # Predicates
  # ============================================================================

  @spec max_iterations?(State.t()) :: boolean()
  def max_iterations?(state) do
    state.counters.iteration >= state.counters.max_iterations
  end

  @spec max_failures?(State.t()) :: boolean()
  def max_failures?(state) do
    state.counters.consecutive_failures >= state.counters.max_failures
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @spec iteration(State.t()) :: non_neg_integer()
  def iteration(state), do: state.counters.iteration

  @spec max_iterations(State.t()) :: pos_integer()
  def max_iterations(state), do: state.counters.max_iterations

  @spec consecutive_failures(State.t()) :: non_neg_integer()
  def consecutive_failures(state), do: state.counters.consecutive_failures

  @spec max_failures(State.t()) :: pos_integer()
  def max_failures(state), do: state.counters.max_failures

  @spec repeat_count(State.t()) :: non_neg_integer()
  def repeat_count(state), do: state.counters.repeat_count

  @spec syntax_failures(State.t()) :: non_neg_integer()
  def syntax_failures(state), do: state.counters.syntax_failures

  @spec goal_tracker_blocks(State.t()) :: non_neg_integer()
  def goal_tracker_blocks(state), do: state.counters.goal_tracker_blocks
end
