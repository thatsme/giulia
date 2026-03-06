defmodule Giulia.Inference.State.TrackingTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.State
  alias Giulia.Inference.State.Tracking

  setup do
    %{state: State.new()}
  end

  # ============================================================================
  # Provider Management
  # ============================================================================

  describe "provider management" do
    test "set_provider/3", %{state: state} do
      state = Tracking.set_provider(state, :anthropic, Giulia.Provider.Anthropic)
      assert Tracking.provider_name(state) == :anthropic
      assert Tracking.provider_module(state) == Giulia.Provider.Anthropic
    end

    test "escalate_provider/3 marks escalation", %{state: state} do
      state = Tracking.set_provider(state, :lm_studio, Giulia.Provider.LMStudio)
      state = Tracking.escalate_provider(state, :anthropic, Giulia.Provider.Anthropic)

      assert Tracking.provider_name(state) == :anthropic
      assert Tracking.escalated?(state) == true
      assert state.provider.original == :lm_studio
    end

    test "mark_escalated/1", %{state: state} do
      refute Tracking.escalated?(state)
      state = Tracking.mark_escalated(state)
      assert Tracking.escalated?(state)
    end

    test "set_last_compile_error/2", %{state: state} do
      state = Tracking.set_last_compile_error(state, "undefined function foo/0")
      assert state.provider.last_compile_error == "undefined function foo/0"

      state = Tracking.set_last_compile_error(state, nil)
      assert state.provider.last_compile_error == nil
    end
  end

  # ============================================================================
  # Verification State
  # ============================================================================

  describe "verification" do
    test "pending_verification", %{state: state} do
      refute Tracking.pending_verification?(state)
      state = Tracking.set_pending_verification(state, true)
      assert Tracking.pending_verification?(state)
    end

    test "test_status", %{state: state} do
      assert Tracking.test_status(state) == :untested
      state = Tracking.set_test_status(state, :green)
      assert Tracking.test_status(state) == :green
    end

    test "baseline", %{state: state} do
      assert Tracking.baseline_status(state) == :unknown
      state = Tracking.set_baseline(state, :clean)
      assert Tracking.baseline_status(state) == :clean
    end
  end

  # ============================================================================
  # Goal Tracker
  # ============================================================================

  describe "goal tracker" do
    test "track_modified_file/2", %{state: state} do
      state = Tracking.track_modified_file(state, "lib/foo.ex")
      state = Tracking.track_modified_file(state, "lib/bar.ex")
      assert MapSet.size(state.goal.modified_files) == 2
    end

    test "track_modified_file/2 deduplicates", %{state: state} do
      state = Tracking.track_modified_file(state, "lib/foo.ex")
      state = Tracking.track_modified_file(state, "lib/foo.ex")
      assert MapSet.size(state.goal.modified_files) == 1
    end

    test "goal_coverage/1 with no impact map", %{state: state} do
      assert Tracking.goal_coverage(state) == 0.0
    end

    test "goal_coverage/1 with impact map", %{state: state} do
      state = Tracking.set_impact_map(state, %{count: 4})
      state = Tracking.track_modified_file(state, "lib/a.ex")
      state = Tracking.track_modified_file(state, "lib/b.ex")
      assert Tracking.goal_coverage(state) == 0.5
    end
  end

  # ============================================================================
  # Repeat Detection
  # ============================================================================

  describe "repeat detection" do
    test "repeating?/2", %{state: state} do
      action = {"read_file", %{"path" => "lib/foo.ex"}}
      refute Tracking.repeating?(state, action)

      state = %{state | last_action: action}
      assert Tracking.repeating?(state, action)
    end

    test "stuck_in_loop?/2", %{state: state} do
      refute Tracking.stuck_in_loop?(state, 3)

      state = put_in(state.counters.repeat_count, 3)
      assert Tracking.stuck_in_loop?(state, 3)
    end
  end
end
