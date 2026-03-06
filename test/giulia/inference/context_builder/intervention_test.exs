defmodule Giulia.Inference.ContextBuilder.InterventionTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.ContextBuilder.Intervention
  alias Giulia.Inference.State

  describe "build_readonly_intervention/2" do
    test "includes tool name and repeat count" do
      state = State.new() |> Map.put(:action_history, [])
      msg = Intervention.build_readonly_intervention("read_file", state)
      assert msg =~ "read_file"
      assert msg =~ "REPETITION ERROR"
      assert msg =~ "PROHIBITED"
    end

    test "includes last result from action history" do
      state = State.new()
      state = %{state | action_history: [{"read_file", %{"path" => "lib/foo.ex"}, {:ok, "contents"}}]}
      msg = Intervention.build_readonly_intervention("read_file", state)
      assert msg =~ "contents"
    end
  end

  describe "build_write_intervention/3" do
    test "includes error summary and action summary" do
      state = State.new()
      state = %{state |
        recent_errors: ["syntax error on line 5", "unexpected token"],
        action_history: [{"edit_file", %{"path" => "lib/foo.ex"}, {:error, "fail"}}]
      }

      msg = Intervention.build_write_intervention(state, "lib/foo.ex", "defmodule Foo do\nend")
      assert msg =~ "INTERVENTION"
      assert msg =~ "CONTEXT PURGE"
      assert msg =~ "lib/foo.ex"
      assert msg =~ "defmodule Foo"
      assert msg =~ "syntax error"
    end

    test "works without fresh content" do
      state = State.new()
      state = %{state | recent_errors: [], action_history: []}
      msg = Intervention.build_write_intervention(state, nil, nil)
      assert msg =~ "INTERVENTION"
      refute msg =~ "CONTEXT PURGE"
    end
  end

  describe "build_intervention_message/3 dispatches" do
    test "dispatches to readonly for read-only tools" do
      state = State.new()
      state = %{state |
        last_action: {"read_file", %{"path" => "lib/foo.ex"}},
        action_history: []
      }

      msg = Intervention.build_intervention_message(state, nil, nil)
      assert msg =~ "REPETITION ERROR"
    end

    test "dispatches to write for write tools" do
      state = State.new()
      state = %{state |
        last_action: {"edit_file", %{"path" => "lib/foo.ex"}},
        recent_errors: [],
        action_history: []
      }

      msg = Intervention.build_intervention_message(state, nil, nil)
      assert msg =~ "INTERVENTION"
      assert msg =~ "stuck in a loop"
    end
  end
end
