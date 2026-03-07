defmodule Giulia.Knowledge.Insights.ImpactTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Insights.Impact

  # ============================================================================
  # pre_impact_check/3 — action dispatch
  # ============================================================================

  describe "pre_impact_check/3 dispatch" do
    test "unknown action returns error" do
      assert {:error, {:unknown_action, "explode"}} =
               Impact.pre_impact_check(Graph.new(), "/tmp", %{"action" => "explode"})
    end

    test "nil action returns error" do
      assert {:error, {:unknown_action, nil}} =
               Impact.pre_impact_check(Graph.new(), "/tmp", %{})
    end
  end

  # ============================================================================
  # rename_function
  # ============================================================================

  describe "rename_function" do
    test "returns impact for function with no callers" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/2", :mfa)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bar/2",
          "new_name" => "baz"
        })

      assert result.action == "rename_function"
      assert result.target == "Foo.bar/2"
      assert result.new_name == "Foo.baz/2"
      assert result.affected_count == 0
      assert result.affected_modules == 0
      assert result.risk_level == "low"
      assert result.phases == [%{phase: 1, description: "Update target definition", modules: ["Foo"]}]
      assert result.warnings == []
    end

    test "returns impact with callers across multiple modules" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/1", :mfa)
        |> Graph.add_vertex("A.call_bar/0", :mfa)
        |> Graph.add_vertex("B.use_bar/1", :mfa)
        |> Graph.add_vertex("C.also_bar/2", :mfa)
        |> Graph.add_edge("A.call_bar/0", "Foo.bar/1")
        |> Graph.add_edge("B.use_bar/1", "Foo.bar/1")
        |> Graph.add_edge("C.also_bar/2", "Foo.bar/1")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bar/1",
          "new_name" => "renamed_bar"
        })

      assert result.affected_count == 3
      assert result.affected_modules == 3
      assert result.new_name == "Foo.renamed_bar/1"
      assert result.risk_score > 0
    end

    test "invalid target format returns error" do
      {:error, {:invalid_target, "noslash"}} =
        Impact.pre_impact_check(Graph.new(), "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "noslash",
          "new_name" => "baz"
        })
    end

    test "function not in graph returns error" do
      {:error, {:not_found, "Foo.missing/3"}} =
        Impact.pre_impact_check(Graph.new(), "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "missing/3",
          "new_name" => "baz"
        })
    end

    test "hub callers generate warnings" do
      # Build a graph where caller A has 10+ in-degree (hub)
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/1", :mfa)
        |> Graph.add_vertex("Hub.call_bar/0", :mfa)
        |> Graph.add_vertex("Hub", :module)
        |> Graph.add_edge("Hub.call_bar/0", "Foo.bar/1")

      # Give Hub 10+ dependents to make it a hub
      graph =
        Enum.reduce(1..12, graph, fn i, g ->
          dep = "Dep#{i}"
          g
          |> Graph.add_vertex(dep, :module)
          |> Graph.add_edge(dep, "Hub")
        end)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bar/1",
          "new_name" => "baz"
        })

      assert Enum.any?(result.warnings, &String.contains?(&1, "HUB CALLER"))
    end
  end

  # ============================================================================
  # remove_function
  # ============================================================================

  describe "remove_function" do
    test "returns impact for function with no callers or callees" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/0", :mfa)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "bar/0"
        })

      assert result.action == "remove_function"
      assert result.target == "Foo.bar/0"
      assert result.affected_count == 0
      assert result.potentially_orphaned == []
      assert result.risk_level == "low"
    end

    test "detects callers and adds BREAKING warning" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/1", :mfa)
        |> Graph.add_vertex("A.uses_bar/0", :mfa)
        |> Graph.add_edge("A.uses_bar/0", "Foo.bar/1")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "bar/1"
        })

      assert result.affected_count == 1
      assert Enum.any?(result.warnings, &String.contains?(&1, "BREAKING"))
    end

    test "detects orphaned callees" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/0", :mfa)
        |> Graph.add_vertex("Foo.helper/0", :mfa)
        |> Graph.add_edge("Foo.bar/0", "Foo.helper/0")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "bar/0"
        })

      assert "Foo.helper/0" in result.potentially_orphaned
    end

    test "function not in graph returns error" do
      {:error, {:not_found, "Foo.ghost/1"}} =
        Impact.pre_impact_check(Graph.new(), "/tmp", %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "ghost/1"
        })
    end
  end

  # ============================================================================
  # rename_module
  # ============================================================================

  describe "rename_module" do
    test "module not in graph returns error" do
      {:error, {:not_found, "Ghost"}} =
        Impact.pre_impact_check(Graph.new(), "/tmp", %{
          "action" => "rename_module",
          "module" => "Ghost",
          "new_name" => "NewGhost"
        })
    end

    test "returns impact for module with dependents" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Old", :module)
        |> Graph.add_vertex("Dep1", :module)
        |> Graph.add_vertex("Dep2", :module)
        |> Graph.add_edge("Dep1", "Old")
        |> Graph.add_edge("Dep2", "Old")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_module",
          "module" => "Old",
          "new_name" => "New"
        })

      assert result.action == "rename_module"
      assert result.target == "Old"
      assert result.new_name == "New"
      assert result.affected_count == 2
      assert result.risk_score > 0
    end

    test "hub module gets high hub penalty" do
      # Module with 15 dependents — triggers in_deg * 3 penalty
      graph =
        Enum.reduce(1..15, Graph.new() |> Graph.add_vertex("Hub", :module), fn i, g ->
          dep = "Dep#{i}"
          g |> Graph.add_vertex(dep, :module) |> Graph.add_edge(dep, "Hub")
        end)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_module",
          "module" => "Hub",
          "new_name" => "NewHub"
        })

      # risk = deps * 5 + hub_penalty (15 * 3 = 45)
      assert result.risk_score == 15 * 5 + 15 * 3
      assert result.risk_level == "high"
      assert Enum.any?(result.warnings, &String.contains?(&1, "HUB MODULE"))
    end
  end

  # ============================================================================
  # enrich_mfa_vertex/2
  # ============================================================================

  describe "enrich_mfa_vertex/2" do
    test "parses valid MFA string" do
      result = Impact.enrich_mfa_vertex("Giulia.Foo.bar/2", "/tmp/nonexistent")
      assert result.mfa == "Giulia.Foo.bar/2"
      assert result.module == "Giulia.Foo"
      assert result.function == "bar"
      assert result.arity == 2
    end

    test "handles unparseable MFA gracefully" do
      result = Impact.enrich_mfa_vertex("not_an_mfa", "/tmp")
      assert result.mfa == "not_an_mfa"
      assert result.module == "not_an_mfa"
      assert result.function == nil
      assert result.arity == nil
    end

    test "handles module-only vertex (no slash)" do
      result = Impact.enrich_mfa_vertex("Giulia.Core.Store", "/tmp")
      assert result.module == "Giulia.Core.Store"
      assert result.function == nil
    end
  end

  # ============================================================================
  # Adversarial: edge cases and malformed inputs
  # ============================================================================

  describe "adversarial inputs" do
    test "empty params map" do
      {:error, {:unknown_action, nil}} =
        Impact.pre_impact_check(Graph.new(), "/tmp", %{})
    end

    test "target with special characters in function name" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.__info__/1", :mfa)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "__info__/1",
          "new_name" => "__meta__"
        })

      assert result.target == "Foo.__info__/1"
      assert result.new_name == "Foo.__meta__/1"
    end

    test "target with zero arity" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.run/0", :mfa)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "run/0",
          "new_name" => "execute"
        })

      assert result.new_name == "Foo.execute/0"
    end

    test "rename_module with no dependents" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Lonely", :module)

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_module",
          "module" => "Lonely",
          "new_name" => "StillLonely"
        })

      assert result.affected_count == 0
      assert result.risk_score == 0
      assert result.risk_level == "low"
    end

    test "phases separate leaf callers from interconnected" do
      # A calls target, B calls target AND depends on A
      graph =
        Graph.new()
        |> Graph.add_vertex("Target.func/1", :mfa)
        |> Graph.add_vertex("Leaf.caller/0", :mfa)
        |> Graph.add_vertex("Inter.caller/0", :mfa)
        |> Graph.add_edge("Leaf.caller/0", "Target.func/1")
        |> Graph.add_edge("Inter.caller/0", "Target.func/1")
        |> Graph.add_edge("Inter", "Leaf")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "rename_function",
          "module" => "Target",
          "target" => "func/1",
          "new_name" => "new_func"
        })

      assert length(result.phases) >= 1
      assert hd(result.phases).phase == 1
      assert hd(result.phases).description == "Update target definition"
    end

    test "enrich_mfa_vertex with deeply nested module name" do
      result = Impact.enrich_mfa_vertex("A.B.C.D.E.func/3", "/tmp")
      assert result.module == "A.B.C.D.E"
      assert result.function == "func"
      assert result.arity == 3
    end

    test "remove_function callee with multiple callers is not orphaned" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/0", :mfa)
        |> Graph.add_vertex("Foo.helper/0", :mfa)
        |> Graph.add_vertex("Other.also_calls/0", :mfa)
        |> Graph.add_edge("Foo.bar/0", "Foo.helper/0")
        |> Graph.add_edge("Other.also_calls/0", "Foo.helper/0")

      {:ok, result} =
        Impact.pre_impact_check(graph, "/tmp", %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "bar/0"
        })

      # helper/0 has another caller, so it should NOT be orphaned
      refute "Foo.helper/0" in result.potentially_orphaned
    end
  end
end
