defmodule Giulia.Inference.State.Tracking do
  @moduledoc """
  Provider, verification, goal, and repeat-detection tracking for the Orchestrator state.

  Manages sub-maps: `state.provider`, `state.verification`, `state.goal`,
  and cross-cutting repeat detection via `state.last_action` and `state.counters`.

  Extracted from `Giulia.Inference.State` (Build 110).
  """

  # Note: uses map() instead of state() to avoid circular dependency
  # (State delegates to Tracking, Tracking would reference state())
  @type state :: map()

  # ============================================================================
  # Provider Management
  # ============================================================================

  @spec set_provider(state(), atom() | String.t(), module()) :: state()
  def set_provider(state, name, module) do
    %{state | provider: %{state.provider | name: name, module: module}}
  end

  @spec escalate_provider(state(), atom() | String.t(), module()) :: state()
  def escalate_provider(state, name, module) do
    %{
      state
      | provider: %{
          state.provider
          | name: name,
            module: module,
            escalated: true,
            original: state.provider.name
        }
    }
  end

  @spec mark_escalated(state()) :: state()
  def mark_escalated(state) do
    put_in(state.provider.escalated, true)
  end

  @spec set_last_compile_error(state(), String.t() | nil) :: state()
  def set_last_compile_error(state, error) do
    put_in(state.provider.last_compile_error, error)
  end

  @spec provider_name(state()) :: atom() | String.t() | nil
  def provider_name(state), do: state.provider.name

  @spec provider_module(state()) :: module() | nil
  def provider_module(state), do: state.provider.module

  @spec escalated?(state()) :: boolean()
  def escalated?(state), do: state.provider.escalated

  # ============================================================================
  # Verification State
  # ============================================================================

  @spec set_pending_verification(state(), boolean()) :: state()
  def set_pending_verification(state, bool) do
    put_in(state.verification.pending, bool)
  end

  @spec set_test_status(state(), :untested | :red | :green) :: state()
  def set_test_status(state, status) do
    put_in(state.verification.test_status, status)
  end

  @spec set_baseline(state(), :clean | :dirty | :unknown) :: state()
  def set_baseline(state, status) do
    put_in(state.verification.baseline, status)
  end

  @spec pending_verification?(state()) :: boolean()
  def pending_verification?(state), do: state.verification.pending

  @spec test_status(state()) :: :untested | :red | :green
  def test_status(state), do: state.verification.test_status

  @spec baseline_status(state()) :: :clean | :dirty | :unknown
  def baseline_status(state), do: state.verification.baseline

  # ============================================================================
  # Goal Tracker
  # ============================================================================

  @spec set_impact_map(state(), map()) :: state()
  def set_impact_map(state, map) do
    put_in(state.goal.last_impact_map, map)
  end

  @spec track_modified_file(state(), String.t()) :: state()
  def track_modified_file(state, path) do
    put_in(state.goal.modified_files, MapSet.put(state.goal.modified_files, path))
  end

  @spec goal_coverage(state()) :: float()
  def goal_coverage(state) do
    case state.goal.last_impact_map do
      %{count: count} when count > 0 ->
        MapSet.size(state.goal.modified_files) / count

      _ ->
        0.0
    end
  end

  # ============================================================================
  # Repeat Detection
  # ============================================================================

  @spec repeating?(state(), {String.t(), map()}) :: boolean()
  def repeating?(state, action) do
    state.last_action == action
  end

  @spec stuck_in_loop?(state(), non_neg_integer()) :: boolean()
  def stuck_in_loop?(state, threshold) do
    state.counters.repeat_count >= threshold
  end
end
