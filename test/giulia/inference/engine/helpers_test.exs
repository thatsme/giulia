defmodule Giulia.Inference.Engine.HelpersTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.Engine.Helpers
  alias Giulia.Inference.State

  describe "done_with_telemetry/2" do
    test "returns {:done, result, state} for ok result" do
      state = State.new()
      assert {:done, {:ok, "msg"}, ^state} = Helpers.done_with_telemetry({:ok, "msg"}, state)
    end

    test "returns {:done, result, state} for error result" do
      state = State.new()
      assert {:done, {:error, :timeout}, ^state} = Helpers.done_with_telemetry({:error, :timeout}, state)
    end
  end
end
