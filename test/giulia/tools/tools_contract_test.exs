defmodule Giulia.Tools.ContractTest do
  @moduledoc """
  Contract tests for all tool modules.

  Every tool MUST implement name/0, description/0, parameters/0, execute/2.
  This test verifies the contract across all 23 tools at once.
  """
  use ExUnit.Case, async: true

  @tools [
    Giulia.Tools.BulkReplace,
    Giulia.Tools.CommitChanges,
    Giulia.Tools.CycleCheck,
    Giulia.Tools.EditFile,
    Giulia.Tools.GetContext,
    Giulia.Tools.GetFunction,
    Giulia.Tools.GetImpactMap,
    Giulia.Tools.GetModuleInfo,
    Giulia.Tools.GetStagedFiles,
    Giulia.Tools.ListFiles,
    Giulia.Tools.LookupFunction,
    Giulia.Tools.PatchFunction,
    Giulia.Tools.ReadFile,
    Giulia.Tools.RenameMFA,
    Giulia.Tools.Respond,
    Giulia.Tools.RunMix,
    Giulia.Tools.RunTests,
    Giulia.Tools.SearchCode,
    Giulia.Tools.SearchMeaning,
    Giulia.Tools.Think,
    Giulia.Tools.TracePath,
    Giulia.Tools.WriteFile,
    Giulia.Tools.WriteFunction
  ]

  for tool <- @tools do
    module_name = tool |> Module.split() |> List.last()

    describe "#{module_name}" do
      test "name/0 returns a non-empty string" do
        Code.ensure_loaded!(unquote(tool))
        name = unquote(tool).name()
        assert is_binary(name)
        assert String.length(name) > 0
      end

      test "description/0 returns a non-empty string" do
        Code.ensure_loaded!(unquote(tool))
        desc = unquote(tool).description()
        assert is_binary(desc)
        assert String.length(desc) > 0
      end

      test "parameters/0 returns a valid schema" do
        Code.ensure_loaded!(unquote(tool))
        params = unquote(tool).parameters()
        assert is_map(params)
        assert params.type == "object"
        assert is_map(params.properties)
      end

      test "execute/2 is exported" do
        Code.ensure_loaded!(unquote(tool))
        assert function_exported?(unquote(tool), :execute, 2)
      end
    end
  end

  # ============================================================================
  # Tool Name Uniqueness
  # ============================================================================

  test "all tool names are unique" do
    names = Enum.map(@tools, fn tool ->
      Code.ensure_loaded!(tool)
      tool.name()
    end)

    assert length(names) == length(Enum.uniq(names)),
           "Duplicate tool names found: #{inspect(names -- Enum.uniq(names))}"
  end

  test "all tool names are snake_case" do
    Enum.each(@tools, fn tool ->
      Code.ensure_loaded!(tool)
      name = tool.name()
      assert name == String.downcase(name), "Tool name '#{name}' is not lowercase"
      refute String.contains?(name, " "), "Tool name '#{name}' contains spaces"
    end)
  end

  test "all parameters schemas have required field" do
    Enum.each(@tools, fn tool ->
      Code.ensure_loaded!(tool)
      params = tool.parameters()
      # required should exist (can be empty list)
      assert Map.has_key?(params, :required) or Map.has_key?(params, "required"),
             "Tool #{tool.name()} missing :required in parameters"
    end)
  end
end
