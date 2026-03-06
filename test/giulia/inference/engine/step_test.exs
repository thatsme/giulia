defmodule Giulia.Inference.Engine.StepTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.Engine.Step
  alias Giulia.Inference.State

  describe "run/1 guards" do
    test "halts when paused" do
      state = State.new() |> State.set_status(:paused)
      assert {:halt, ^state} = Step.run(state)
    end

    test "halts when waiting for approval" do
      state = State.new() |> State.set_status(:waiting_for_approval)
      assert {:halt, ^state} = Step.run(state)
    end

    test "returns done when max iterations reached" do
      state = State.new(max_iterations: 1)
      state = State.increment_iteration(state)
      assert {:done, {:error, :max_iterations_exceeded}, _} = Step.run(state)
    end

    test "intervenes when max failures reached" do
      state = State.new()
      state = state
        |> State.increment_failures()
        |> State.increment_failures()
        |> State.increment_failures()
      assert {:next, :intervene, _} = Step.run(state)
    end
  end
end
