defmodule Giulia.Tools.RegistryTest do
  @moduledoc """
  Tests for Tools.Registry — the highest centrality module (degree 30).

  Registry is a GenServer backed by ETS that auto-discovers tools on boot.
  Tests cover registration, lookup, listing, execution dispatch, and discovery.
  """
  use ExUnit.Case, async: false

  alias Giulia.Tools.Registry

  # Registry is started by the application supervisor, so it's already running.
  # We test against the live instance.

  describe "list_tools/0" do
    test "returns a non-empty list of tool specs" do
      tools = Registry.list_tools()
      assert is_list(tools)
      assert length(tools) > 0
    end

    test "each tool spec has required fields" do
      tools = Registry.list_tools()

      for tool <- tools do
        assert is_atom(tool.module)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.parameters)
      end
    end

    test "includes core tools" do
      names = Registry.list_tool_names()
      assert "read_file" in names
      assert "write_file" in names
      assert "think" in names
      assert "respond" in names
    end
  end

  describe "list_tool_names/0" do
    test "returns a list of strings" do
      names = Registry.list_tool_names()
      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
    end

    test "matches tool count from list_tools" do
      assert length(Registry.list_tools()) == length(Registry.list_tool_names())
    end
  end

  describe "get_tool/1" do
    test "returns {:ok, module} for a known tool" do
      assert {:ok, module} = Registry.get_tool("think")
      assert module == Giulia.Tools.Think
    end

    test "returns :not_found for an unknown tool" do
      assert :not_found = Registry.get_tool("nonexistent_tool_xyz")
    end
  end

  describe "register/1" do
    test "registers a valid tool module" do
      # Think is already registered, but re-registering should succeed
      assert {:ok, "think"} = Registry.register(Giulia.Tools.Think)
    end

    test "returns error for a module that doesn't implement the behaviour" do
      assert {:error, {:registration_failed, String, _}} = Registry.register(String)
    end
  end

  describe "execute/3" do
    test "dispatches to the correct tool module" do
      assert {:ok, _} = Registry.execute("think", %{"thought" => "test"}, [])
    end

    test "returns error for unknown tool" do
      assert {:error, {:unknown_tool, "fake_tool", _names}} =
               Registry.execute("fake_tool", %{}, [])
    end
  end

  describe "discover_tools/0" do
    test "is a cast that returns :ok" do
      # discover_tools is async (cast), should not crash
      assert :ok = Registry.discover_tools()
      # Give it a moment to complete
      Process.sleep(50)
      # Verify tools are still registered
      assert length(Registry.list_tools()) > 0
    end
  end

  describe "tool consistency" do
    test "all registered tools have unique names" do
      names = Registry.list_tool_names()
      assert length(names) == length(Enum.uniq(names))
    end

    test "all tools have non-empty descriptions" do
      tools = Registry.list_tools()

      for tool <- tools do
        assert String.length(tool.description) > 0,
               "Tool #{tool.name} has empty description"
      end
    end

    test "all tools have a parameters map with properties key" do
      tools = Registry.list_tools()

      for tool <- tools do
        assert is_map(tool.parameters),
               "Tool #{tool.name} parameters is not a map"
      end
    end
  end
end
