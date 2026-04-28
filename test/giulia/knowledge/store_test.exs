defmodule Giulia.Knowledge.StoreTest do
  @moduledoc """
  Tests for Knowledge.Store — GenServer wrapping Builder and Analyzer.

  Knowledge.Store is the stateful shell: it holds per-project graphs and
  delegates construction to Builder and analytics to Analyzer.

  Note: async: false because it uses named GenServers (Context.Store + Knowledge.Store).
  """
  use ExUnit.Case, async: false

  alias Giulia.Knowledge.Store
  alias Giulia.Context.Store, as: ContextStore

  @project "/test/knowledge_project"

  setup do
    # Ensure Context.Store is running (for ETS)
    case Process.whereis(ContextStore) do
      nil -> start_supervised!({ContextStore, []})
      _pid -> :ok
    end

    # Ensure Knowledge.Store is running
    case Process.whereis(Store) do
      nil -> start_supervised!({Store, []})
      _pid -> :ok
    end

    # Clean up
    ContextStore.clear_asts(@project)
    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp populate_and_rebuild do
    # Populate Context.Store with AST data
    ContextStore.put_ast(@project, "lib/alpha.ex", %{
      modules: [%{name: "Alpha", line: 1}],
      functions: [
        %{name: :run, arity: 1, type: :def, line: 3},
        %{name: :stop, arity: 0, type: :def, line: 10}
      ],
      imports: [%{module: "Beta", type: :alias, line: 2}],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    ContextStore.put_ast(@project, "lib/beta.ex", %{
      modules: [%{name: "Beta", line: 1}],
      functions: [
        %{name: :process, arity: 2, type: :def, line: 3}
      ],
      imports: [],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    ContextStore.put_ast(@project, "lib/gamma.ex", %{
      modules: [%{name: "Gamma", line: 1}],
      functions: [
        %{name: :transform, arity: 1, type: :def, line: 3}
      ],
      imports: [%{module: "Beta", type: :alias, line: 2}],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    # Synchronous rebuild with explicit AST data
    ast_data = ContextStore.all_asts(@project)
    :ok = Store.rebuild(@project, ast_data)
  end

  # ============================================================================
  # Rebuild & Stats
  # ============================================================================

  describe "rebuild/2 and stats/1" do
    test "synchronous rebuild creates graph with correct vertex count" do
      populate_and_rebuild()
      stats = Store.stats(@project)
      # 3 modules + their functions
      assert stats.vertices >= 3
      assert stats.edges >= 0
    end

    test "empty project produces empty graph" do
      :ok = Store.rebuild(@project, %{})
      stats = Store.stats(@project)
      assert stats.vertices == 0
      assert stats.edges == 0
    end
  end

  # ============================================================================
  # Centrality
  # ============================================================================

  describe "centrality/2" do
    test "hub module has higher in-degree" do
      populate_and_rebuild()
      # Beta is depended on by Alpha and Gamma
      assert {:ok, info} = Store.centrality(@project, "Beta")
      assert info.in_degree == 2
    end

    test "leaf module has zero in-degree" do
      populate_and_rebuild()
      assert {:ok, info} = Store.centrality(@project, "Alpha")
      assert info.in_degree == 0
    end

    test "unknown module returns error" do
      populate_and_rebuild()
      assert {:error, {:not_found, "NonExistent"}} = Store.centrality(@project, "NonExistent")
    end
  end

  # ============================================================================
  # Dependents & Dependencies
  # ============================================================================

  describe "dependents/2" do
    test "returns modules that depend on target" do
      populate_and_rebuild()
      assert {:ok, deps} = Store.dependents(@project, "Beta")
      assert "Alpha" in deps
      assert "Gamma" in deps
    end

    test "leaf module has no dependents" do
      populate_and_rebuild()
      assert {:ok, deps} = Store.dependents(@project, "Alpha")
      assert deps == []
    end
  end

  describe "dependencies/2" do
    test "returns modules that target depends on" do
      populate_and_rebuild()
      assert {:ok, deps} = Store.dependencies(@project, "Alpha")
      assert deps == ["Beta"]
    end

    test "root module has no dependencies" do
      populate_and_rebuild()
      assert {:ok, deps} = Store.dependencies(@project, "Beta")
      assert deps == []
    end
  end

  # ============================================================================
  # Impact Map
  # ============================================================================

  describe "impact_map/3" do
    test "returns upstream and downstream for module" do
      populate_and_rebuild()
      assert {:ok, result} = Store.impact_map(@project, "Beta", 2)
      assert result.vertex == "Beta"

      downstream_ids = Enum.map(result.downstream, fn {v, _d} -> v end)
      assert "Alpha" in downstream_ids
      assert "Gamma" in downstream_ids
    end

    test "returns error with suggestions for unknown module" do
      populate_and_rebuild()
      assert {:error, {:not_found, "Bet", _matches, _meta}} =
               Store.impact_map(@project, "Bet", 1)
    end
  end

  # ============================================================================
  # Trace Path
  # ============================================================================

  describe "trace_path/3" do
    test "finds path between connected modules" do
      populate_and_rebuild()
      assert {:ok, path} = Store.trace_path(@project, "Alpha", "Beta")
      assert is_list(path)
      assert hd(path) == "Alpha"
      assert List.last(path) == "Beta"
    end

    test "returns :no_path for unreachable modules" do
      populate_and_rebuild()
      # Beta doesn't depend on Alpha, so reverse path doesn't exist
      assert {:ok, :no_path} = Store.trace_path(@project, "Beta", "Alpha")
    end
  end

  # ============================================================================
  # Cycles
  # ============================================================================

  describe "find_cycles/1" do
    test "no cycles in acyclic graph" do
      populate_and_rebuild()
      assert {:ok, result} = Store.find_cycles(@project)
      assert result.count == 0
    end

    test "detects cycle when present" do
      # Add a cycle: Beta -> Alpha (Alpha already depends on Beta)
      ContextStore.clear_asts(@project)
      ContextStore.put_ast(@project, "lib/alpha.ex", %{
        modules: [%{name: "Alpha", line: 1}],
        functions: [],
        imports: [%{module: "Beta", type: :alias, line: 2}],
        structs: [], callbacks: [], types: [], specs: [], docs: []
      })
      ContextStore.put_ast(@project, "lib/beta.ex", %{
        modules: [%{name: "Beta", line: 1}],
        functions: [],
        imports: [%{module: "Alpha", type: :alias, line: 2}],
        structs: [], callbacks: [], types: [], specs: [], docs: []
      })

      ast_data = ContextStore.all_asts(@project)
      :ok = Store.rebuild(@project, ast_data)

      assert {:ok, result} = Store.find_cycles(@project)
      assert result.count == 1
      cycle = hd(result.cycles)
      assert "Alpha" in cycle
      assert "Beta" in cycle
    end
  end

  # ============================================================================
  # Graph Access
  # ============================================================================

  describe "graph/1" do
    test "returns the raw graph struct" do
      populate_and_rebuild()
      graph = Store.graph(@project)
      assert Graph.num_vertices(graph) >= 3
    end

    test "empty project returns empty or default graph" do
      # Use a fresh project path to avoid leaking state from other tests
      graph = Store.graph("/test/empty_graph_project")
      assert Graph.num_vertices(graph) == 0
    end
  end

  # ============================================================================
  # Semantic Edges
  # ============================================================================

  describe "add_semantic_edge/4" do
    test "adds semantic edge to graph" do
      populate_and_rebuild()
      assert :ok = Store.add_semantic_edge(@project, "Alpha", "Gamma", "similar_pattern")

      graph = Store.graph(@project)
      edges = Graph.edges(graph, "Alpha", "Gamma")
      assert Enum.any?(edges, fn e ->
        match?({:semantic, "similar_pattern"}, e.label)
      end)
    end
  end

  # ============================================================================
  # Implementers
  # ============================================================================

  describe "get_implementers/2" do
    test "returns implementers of a behaviour" do
      # Set up a behaviour + implementer
      ContextStore.clear_asts(@project)
      ContextStore.put_ast(@project, "lib/behaviour.ex", %{
        modules: [%{name: "MyBehaviour", line: 1}],
        functions: [],
        imports: [],
        structs: [],
        callbacks: [%{function: :run, arity: 1, line: 2}],
        types: [], specs: [], docs: []
      })
      ContextStore.put_ast(@project, "lib/impl.ex", %{
        modules: [%{name: "MyImpl", line: 1}],
        functions: [%{name: :run, arity: 1, type: :def, line: 3}],
        imports: [%{module: "MyBehaviour", type: :use, line: 2}],
        structs: [], callbacks: [], types: [], specs: [], docs: []
      })

      ast_data = ContextStore.all_asts(@project)
      :ok = Store.rebuild(@project, ast_data)

      assert {:ok, impls} = Store.get_implementers(@project, "MyBehaviour")
      assert "MyImpl" in impls
    end

    test "returns empty list for non-behaviour" do
      populate_and_rebuild()
      assert {:ok, impls} = Store.get_implementers(@project, "Alpha")
      assert impls == []
    end
  end

  # ============================================================================
  # Multi-project isolation
  # ============================================================================

  describe "multi-project isolation" do
    test "graphs are isolated per project" do
      project_a = "/proj/a"
      project_b = "/proj/b"

      ContextStore.put_ast(project_a, "lib/a.ex", %{
        modules: [%{name: "ModA", line: 1}],
        functions: [], imports: [], structs: [], callbacks: [],
        types: [], specs: [], docs: []
      })
      ContextStore.put_ast(project_b, "lib/b.ex", %{
        modules: [%{name: "ModB", line: 1}],
        functions: [], imports: [], structs: [], callbacks: [],
        types: [], specs: [], docs: []
      })

      :ok = Store.rebuild(project_a, ContextStore.all_asts(project_a))
      :ok = Store.rebuild(project_b, ContextStore.all_asts(project_b))

      graph_a = Store.graph(project_a)
      graph_b = Store.graph(project_b)

      assert Graph.has_vertex?(graph_a, "ModA")
      refute Graph.has_vertex?(graph_a, "ModB")
      assert Graph.has_vertex?(graph_b, "ModB")
      refute Graph.has_vertex?(graph_b, "ModA")

      # Cleanup
      ContextStore.clear_asts(project_a)
      ContextStore.clear_asts(project_b)
    end
  end

  describe "all_dependencies_with_rollup/1" do
    # The plain `all_dependencies/1` filters to module↔module edges, which
    # silently hides Pass 7-11's synthesized edges (protocol_impl,
    # behaviour_impl, router_dispatch, mfa_ref, etc.) — those go
    # module→function or function→function. The rollup variant exists so
    # /api/knowledge/topology can render a faithful module graph instead
    # of a graph where defimpls and controller actions look isolated.

    test "rolls a module→function edge up to a module→module edge" do
      project = "/test/rollup_module_to_function"

      # Seed a graph that mirrors Pass 7's shape: protocol module has a
      # synthesized edge to a function vertex inside an impl module.
      g =
        Graph.new(type: :directed)
        |> Graph.add_vertex("MyProto", :module)
        |> Graph.add_vertex("MyProto.For.User", :module)
        |> Graph.add_vertex("MyProto.For.User.encode/1", :function)
        |> Graph.add_edge("MyProto", "MyProto.For.User.encode/1",
          label: {:calls, :protocol_impl}
        )

      :ok = Store.restore_graph(project, g)

      {:ok, edges} = Store.all_dependencies_with_rollup(project)

      assert {"MyProto", "MyProto.For.User", :calls} in edges,
             "function endpoint must roll up to its parent module so the " <>
               "topology view sees the protocol→impl connection"

      # Plain all_dependencies should NOT contain it — the function vertex
      # disqualifies the edge from the module-only filter.
      {:ok, plain} = Store.all_dependencies(project)
      refute {"MyProto", "MyProto.For.User", :calls} in plain
    end

    test "drops self-loops introduced by recursive impl bodies" do
      project = "/test/rollup_self_loop"

      # An impl that recurses into its own protocol via its own function
      # produces a function→function edge whose endpoints both roll up
      # to the same module. Without the self-loop guard these would
      # render as module-pointing-at-itself edges.
      g =
        Graph.new(type: :directed)
        |> Graph.add_vertex("MyImpl", :module)
        |> Graph.add_vertex("MyImpl.encode/1", :function)
        |> Graph.add_vertex("MyImpl.helper/1", :function)
        |> Graph.add_edge("MyImpl.encode/1", "MyImpl.helper/1",
          label: {:calls, :direct}
        )

      :ok = Store.restore_graph(project, g)

      {:ok, edges} = Store.all_dependencies_with_rollup(project)

      refute Enum.any?(edges, fn {s, t, _} -> s == "MyImpl" and t == "MyImpl" end),
             "self-loops produced by intra-module rollup must be dropped"
    end

    test "skips edges whose function endpoints can't be attributed to any module" do
      project = "/test/rollup_orphan_function"

      # A function vertex whose parent module isn't in the graph (could
      # happen for a stale edge or a function vertex from outside the
      # project's module set) must not produce a phantom module edge.
      g =
        Graph.new(type: :directed)
        |> Graph.add_vertex("KnownMod", :module)
        |> Graph.add_vertex("KnownMod.fn/0", :function)
        |> Graph.add_vertex("UnknownMod.other/0", :function)
        |> Graph.add_edge("KnownMod.fn/0", "UnknownMod.other/0",
          label: {:calls, :direct}
        )

      :ok = Store.restore_graph(project, g)

      {:ok, edges} = Store.all_dependencies_with_rollup(project)

      refute Enum.any?(edges, fn {_s, t, _} -> t == "UnknownMod" end),
             "function endpoints that don't map to a known project module " <>
               "must be skipped, not invented as new module vertices"
    end

    test "preserves direct module↔module edges from the plain query" do
      project = "/test/rollup_passthrough"

      g =
        Graph.new(type: :directed)
        |> Graph.add_vertex("ModA", :module)
        |> Graph.add_vertex("ModB", :module)
        |> Graph.add_edge("ModA", "ModB", label: :depends_on)

      :ok = Store.restore_graph(project, g)

      {:ok, plain} = Store.all_dependencies(project)
      {:ok, rolled} = Store.all_dependencies_with_rollup(project)

      assert {"ModA", "ModB", :depends_on} in plain
      assert {"ModA", "ModB", :depends_on} in rolled
    end
  end
end
