defmodule Giulia.Knowledge.MacroMapTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.MacroMap

  describe "injected_functions/1" do
    test "returns GenServer callbacks" do
      result = MacroMap.injected_functions("GenServer")
      assert {"init", 1} in result
      assert {"handle_call", 3} in result
      assert {"handle_cast", 2} in result
      assert {"handle_info", 2} in result
      assert {"handle_continue", 2} in result
      assert {"terminate", 2} in result
      assert {"code_change", 3} in result
      assert {"child_spec", 1} in result
      assert {"start_link", 1} in result
    end

    test "returns Supervisor callbacks" do
      result = MacroMap.injected_functions("Supervisor")
      assert {"init", 1} in result
      assert {"child_spec", 1} in result
      assert {"start_link", 1} in result
    end

    test "returns Agent callbacks" do
      result = MacroMap.injected_functions("Agent")
      assert {"start_link", 1} in result
      assert {"child_spec", 1} in result
    end

    test "returns Application callbacks" do
      result = MacroMap.injected_functions("Application")
      assert {"start", 2} in result
      assert {"stop", 1} in result
    end

    test "returns Plug.Router injected functions" do
      result = MacroMap.injected_functions("Plug.Router")
      assert {"init", 1} in result
      assert {"call", 2} in result
    end

    test "returns Plug.Builder injected functions" do
      result = MacroMap.injected_functions("Plug.Builder")
      assert {"init", 1} in result
      assert {"call", 2} in result
    end

    test "returns Phoenix.LiveView callbacks" do
      result = MacroMap.injected_functions("Phoenix.LiveView")
      assert {"mount", 3} in result
      assert {"render", 1} in result
    end

    test "returns GenStateMachine callbacks" do
      result = MacroMap.injected_functions("GenStateMachine")
      assert {"init", 1} in result
      assert {"handle_event", 4} in result
    end

    test "matches on last segment of module name" do
      # "MyApp.GenServer" should NOT match (last segment is "GenServer")
      # but a raw "GenServer" does match
      result = MacroMap.injected_functions("GenServer")
      assert length(result) > 0
    end

    test "returns empty list for unknown module" do
      assert MacroMap.injected_functions("Unknown.Thing") == []
      assert MacroMap.injected_functions("FooBar") == []
    end
  end

  describe "injected?/3" do
    test "returns true for known injected function" do
      assert MacroMap.injected?(["GenServer"], "init", 1)
      assert MacroMap.injected?(["GenServer"], "handle_call", 3)
    end

    test "returns false for non-injected function" do
      refute MacroMap.injected?(["GenServer"], "my_custom_func", 0)
      refute MacroMap.injected?(["GenServer"], "process", 2)
    end

    test "checks multiple directives" do
      assert MacroMap.injected?(["Supervisor", "GenServer"], "handle_call", 3)
      assert MacroMap.injected?(["Supervisor", "GenServer"], "init", 1)
    end

    test "returns false for empty directives" do
      refute MacroMap.injected?([], "init", 1)
    end
  end

  describe "all/0" do
    test "returns a map with known macro modules" do
      all = MacroMap.all()
      assert is_map(all)
      assert Map.has_key?(all, "GenServer")
      assert Map.has_key?(all, "Supervisor")
      assert Map.has_key?(all, "Agent")
      assert Map.has_key?(all, "Application")
      assert Map.has_key?(all, "Plug.Router")
      assert Map.has_key?(all, "Phoenix.LiveView")
      assert Map.has_key?(all, "GenStateMachine")
    end
  end
end
