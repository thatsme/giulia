defmodule Giulia.Inference.EngineTest do
  @moduledoc """
  THE SOVEREIGN PROOF

  The Engine is the "Brain" of Giulia's inference loop. These tests prove that
  its decision-making is deterministic: given the same state, it ALWAYS
  produces the same directive.

  Directive types:
    {:next, action, state}  — continue to next inference step
    {:done, result, state}  — task complete, reply to caller
    {:halt, state}          — wait (paused, approval pending)

  Section 1: Guard Clause Determinism (pure, zero deps)
  Section 2: Guard Priority / Clause Ordering (pure)
  Section 3: Self-Correction Path (needs Application)
  Section 4: Full Cycle Proof (needs Application)
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.{Engine, State}

  # ============================================================================
  # Section 1: GUARD CLAUSE DETERMINISM — Pure Pattern Matching
  #
  # These tests have ZERO external dependencies. They prove the Engine's
  # dispatch guards are deterministic through pure struct matching.
  # ============================================================================

  describe "dispatch(:step) — halt when paused" do
    test "paused state produces {:halt, state}" do
      state = State.new() |> State.set_status(:paused)

      assert {:halt, ^state} = Engine.dispatch(:step, state)
    end

    test "paused with accumulated state still halts (no side effects)" do
      state =
        State.new()
        |> State.set_status(:paused)
        |> State.set_task("some task")
        |> State.increment_iteration()
        |> State.increment_failures()

      assert {:halt, ^state} = Engine.dispatch(:step, state)
    end
  end

  describe "dispatch(:step) — halt when waiting for approval" do
    test "waiting_for_approval state produces {:halt, state}" do
      state = State.new() |> State.set_status(:waiting_for_approval)

      assert {:halt, ^state} = Engine.dispatch(:step, state)
    end
  end

  describe "dispatch(:step) — max iterations exceeded" do
    test "at exact boundary (iteration == max) produces :max_iterations_exceeded" do
      state =
        State.new(max_iterations: 10)
        |> State.set_status(:thinking)

      state = put_in(state.counters.iteration, 10)

      assert {:done, {:error, :max_iterations_exceeded}, _} = Engine.dispatch(:step, state)
    end

    test "above boundary still triggers" do
      state =
        State.new(max_iterations: 5)
        |> State.set_status(:thinking)

      state = put_in(state.counters.iteration, 100)

      assert {:done, {:error, :max_iterations_exceeded}, _} = Engine.dispatch(:step, state)
    end

    test "minimum max_iterations (1) triggers at iteration 1" do
      state =
        State.new(max_iterations: 1)
        |> State.set_status(:thinking)

      state = put_in(state.counters.iteration, 1)

      assert {:done, {:error, :max_iterations_exceeded}, _} = Engine.dispatch(:step, state)
    end

    test "returned state is unchanged (guard is read-only)" do
      state =
        State.new(max_iterations: 5)
        |> State.set_status(:thinking)

      state = put_in(state.counters.iteration, 5)

      {:done, {:error, :max_iterations_exceeded}, returned_state} =
        Engine.dispatch(:step, state)

      assert returned_state == state
    end
  end

  describe "dispatch(:step) — consecutive failures trigger self-correction" do
    test "at default max_failures (3) triggers {:next, :intervene}" do
      state = build_failed_state(3)

      assert {:next, :intervene, _} = Engine.dispatch(:step, state)
    end

    test "custom max_failures threshold (1) triggers on first failure" do
      state =
        State.new(max_failures: 1)
        |> State.set_status(:thinking)
        |> State.increment_failures()

      assert {:next, :intervene, _} = Engine.dispatch(:step, state)
    end

    test "above threshold still triggers" do
      state = build_failed_state(5)

      assert {:next, :intervene, _} = Engine.dispatch(:step, state)
    end

    test "state is passed through unchanged (guard is read-only)" do
      state = build_failed_state(3)

      {:next, :intervene, returned_state} = Engine.dispatch(:step, state)

      assert returned_state == state
      assert State.consecutive_failures(returned_state) == 3
    end
  end

  # ============================================================================
  # Section 2: GUARD PRIORITY — Clause Ordering
  #
  # When multiple guards could match, Elixir uses first-match-wins.
  # These tests prove the priority order is correct.
  # ============================================================================

  describe "guard priority" do
    test "paused takes priority over max_iterations" do
      state =
        State.new(max_iterations: 5)
        |> State.set_status(:paused)

      state = put_in(state.counters.iteration, 100)

      # Both :paused and max_iterations could match.
      # :paused clause comes first — halt, not done.
      assert {:halt, _} = Engine.dispatch(:step, state)
    end

    test "waiting_for_approval takes priority over max_iterations" do
      state =
        State.new(max_iterations: 5)
        |> State.set_status(:waiting_for_approval)

      state = put_in(state.counters.iteration, 100)

      assert {:halt, _} = Engine.dispatch(:step, state)
    end

    test "max_iterations takes priority over max_failures" do
      state =
        State.new(max_iterations: 5)
        |> State.set_status(:thinking)
        |> State.increment_failures()
        |> State.increment_failures()
        |> State.increment_failures()

      state = put_in(state.counters.iteration, 5)

      # Both max_iterations and max_failures could fire.
      # max_iterations clause comes first — :done, not :intervene.
      assert {:done, {:error, :max_iterations_exceeded}, _} = Engine.dispatch(:step, state)
    end

    test "paused takes priority over max_failures" do
      state = build_failed_state(3) |> State.set_status(:paused)

      # Paused halts even with max failures
      assert {:halt, _} = Engine.dispatch(:step, state)
    end
  end

  # ============================================================================
  # Section 3: SELF-CORRECTION PATH — The Intervention
  #
  # When the Engine detects repeated failures, it enters self-correction:
  # 1. dispatch(:step) sees failures >= max → {:next, :intervene, state}
  # 2. dispatch(:intervene) purges context, resets state → {:next, :step, state}
  #
  # These tests prove the Brain can recover without external intervention.
  #
  # NOTE: dispatch(:intervene) calls Builder.build_tiered_prompt which
  # requires the Application to be started (Registry GenServer + model tier).
  # In `mix test`, the Application starts automatically.
  # ============================================================================

  describe "dispatch(:intervene) — context purge and self-correction" do
    setup do
      # Pre-seed model tier cache to avoid hitting LM Studio
      Application.put_env(:giulia, :detected_model_tier, :high)
      Application.put_env(:giulia, :detected_model_name, "test-model")
      :ok
    end

    test "returns {:next, :step} — resumes thinking loop" do
      state = build_failed_state(3)

      assert {:next, :step, _} = Engine.dispatch(:intervene, state)
    end

    test "resets consecutive_failures to zero" do
      state = build_failed_state(3)

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      assert State.consecutive_failures(new_state) == 0
    end

    test "clears action_history (amnesia by design)" do
      state =
        build_failed_state(3)
        |> State.record_action({"read_file", %{"path" => "a.ex"}, {:ok, "content"}})
        |> State.record_action({"edit_file", %{"file" => "a.ex"}, {:error, "syntax error"}})

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      assert new_state.action_history == []
    end

    test "clears recent_errors" do
      state =
        build_failed_state(3)
        |> State.push_error("compile error on line 42")
        |> State.push_error("syntax error near 'end'")

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      assert new_state.recent_errors == []
    end

    test "sets status to :thinking" do
      state = build_failed_state(3)

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      assert new_state.status == :thinking
    end

    test "builds exactly 4 fresh messages (system, task, ack, intervention)" do
      state =
        build_failed_state(3)
        |> State.set_messages([
          %{role: "system", content: "old system prompt"},
          %{role: "user", content: "fix the bug"},
          %{role: "assistant", content: "trying..."},
          %{role: "user", content: "that broke it"},
          %{role: "assistant", content: "trying again..."},
          %{role: "user", content: "still broken"}
        ])

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      # Old 6 messages replaced by exactly 4 fresh ones
      assert length(new_state.messages) == 4
      assert Enum.at(new_state.messages, 0).role == "system"
      assert Enum.at(new_state.messages, 1).role == "user"
      assert Enum.at(new_state.messages, 2).role == "assistant"
      assert Enum.at(new_state.messages, 3).role == "user"
    end

    test "preserves original task in fresh messages" do
      state = build_failed_state(3)

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      task_msg = Enum.at(new_state.messages, 1)
      assert task_msg.content == "fix the bug"
    end

    test "assistant acknowledges fresh start" do
      state = build_failed_state(3)

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      ack_msg = Enum.at(new_state.messages, 2)
      assert ack_msg.content == "I need to try a different approach."
    end

    test "intervention message contains purge notice" do
      state = build_failed_state(3)

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      intervention = Enum.at(new_state.messages, 3).content
      assert String.contains?(intervention, "INTERVENTION")
    end

    test "patch_function failure injects tool-switch hint" do
      state =
        build_failed_state(3)
        |> State.push_action({"patch_function", %{"module" => "Foo"}})

      {:next, :step, new_state} = Engine.dispatch(:intervene, state)

      intervention = Enum.at(new_state.messages, 3).content
      assert String.contains?(intervention, "patch_function has failed repeatedly")
      assert String.contains?(intervention, "edit_file")
    end
  end

  # ============================================================================
  # Section 4: FULL SELF-CORRECTION CYCLE — End-to-End Determinism
  #
  # The complete proof: failures accumulate → guard fires → intervention
  # purges context → Engine is ready to retry with a clean slate.
  # ============================================================================

  describe "full self-correction cycle" do
    setup do
      Application.put_env(:giulia, :detected_model_tier, :high)
      Application.put_env(:giulia, :detected_model_name, "test-model")
      :ok
    end

    test "failures → guard → intervene → fresh context → ready to retry" do
      # Stage 1: Accumulate 3 consecutive failures
      state = build_failed_state(3)

      # Stage 2: Guard detects threshold, triggers intervention
      assert {:next, :intervene, failed_state} = Engine.dispatch(:step, state)
      assert State.consecutive_failures(failed_state) == 3

      # Stage 3: Intervention purges context, resets state
      assert {:next, :step, healed_state} = Engine.dispatch(:intervene, failed_state)

      # Stage 4: The Sovereign Proof — deterministic self-correction
      #
      # The Brain has healed itself:
      assert State.consecutive_failures(healed_state) == 0
      assert healed_state.action_history == []
      assert healed_state.recent_errors == []
      assert healed_state.status == :thinking

      # Fresh context with 4 messages (system, task, ack, intervention):
      assert length(healed_state.messages) == 4

      # The original task is preserved — the Brain knows WHAT to do:
      assert Enum.at(healed_state.messages, 1).content == "fix the bug"

      # But the HOW is fresh — no contamination from failed attempts.
      # This is the deterministic guarantee: same failures, same recovery.
    end

    test "self-correction is idempotent (same input, same output)" do
      state = build_failed_state(3)

      # Run the cycle twice with identical initial state
      {:next, :intervene, _} = Engine.dispatch(:step, state)
      {:next, :step, result_a} = Engine.dispatch(:intervene, state)

      {:next, :intervene, _} = Engine.dispatch(:step, state)
      {:next, :step, result_b} = Engine.dispatch(:intervene, state)

      # Same input → same output (deterministic)
      assert result_a.messages == result_b.messages
      assert result_a.status == result_b.status
      assert State.consecutive_failures(result_a) == State.consecutive_failures(result_b)
      assert result_a.action_history == result_b.action_history
      assert result_a.recent_errors == result_b.recent_errors
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Build a state with N consecutive failures, ready to trigger self-correction.
  # Uses a task string WITHOUT file path patterns to avoid triggering
  # file reads during intervention (keeps tests fast).
  defp build_failed_state(n) do
    state =
      State.new()
      |> State.set_status(:thinking)
      |> State.set_task("fix the bug")

    Enum.reduce(1..n, state, fn _i, acc -> State.increment_failures(acc) end)
  end
end
