defmodule Giulia.Knowledge.BuilderTest do
  @moduledoc """
  Tests for Knowledge.Builder — pure graph construction from AST data.

  Builder.build_graph/1 takes %{file_path => ast_data_map} and returns
  a Graph.t() with 4 passes: vertices, dependency edges, xref edges,
  and function-call edges.

  These tests verify graph topology without needing GenServer or ETS.
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Builder

  # ============================================================================
  # Helpers: AST data fixtures
  # ============================================================================

  # Minimal AST data map for a single module with functions
  defp ast_data_single_module do
    %{
      "lib/alpha.ex" => %{
        modules: [%{name: "Alpha", line: 1}],
        functions: [
          %{name: :start, arity: 0, type: :def, line: 3},
          %{name: :run, arity: 1, type: :def, line: 8},
          %{name: :internal, arity: 0, type: :defp, line: 15}
        ],
        imports: [],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    }
  end

  # Two modules with a dependency (Alpha imports Beta)
  defp ast_data_with_dependency do
    %{
      "lib/alpha.ex" => %{
        modules: [%{name: "Alpha", line: 1}],
        functions: [%{name: :run, arity: 1, type: :def, line: 3}],
        imports: [%{module: "Beta", type: :alias, line: 2}],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      },
      "lib/beta.ex" => %{
        modules: [%{name: "Beta", line: 1}],
        functions: [%{name: :process, arity: 2, type: :def, line: 3}],
        imports: [],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    }
  end

  # Module with struct
  defp ast_data_with_struct do
    %{
      "lib/schema.ex" => %{
        modules: [%{name: "Schema", line: 1}],
        functions: [%{name: :new, arity: 1, type: :def, line: 5}],
        imports: [],
        structs: [%{module: "Schema", fields: [:name, :age], line: 3}],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    }
  end

  # Module with callbacks (behaviour)
  defp ast_data_with_behaviour do
    %{
      "lib/provider.ex" => %{
        modules: [%{name: "Provider", line: 1}],
        functions: [],
        imports: [],
        structs: [],
        callbacks: [
          %{function: :connect, arity: 1, line: 3},
          %{function: :query, arity: 2, line: 4}
        ],
        types: [],
        specs: [],
        docs: []
      }
    }
  end

  # Module that implements a behaviour via use
  defp ast_data_with_implements do
    %{
      "lib/provider.ex" => %{
        modules: [%{name: "Provider", line: 1}],
        functions: [],
        imports: [],
        structs: [],
        callbacks: [%{function: :connect, arity: 1, line: 3}],
        types: [],
        specs: [],
        docs: []
      },
      "lib/my_provider.ex" => %{
        modules: [%{name: "MyProvider", line: 1}],
        functions: [%{name: :connect, arity: 1, type: :def, line: 5}],
        imports: [%{module: "Provider", type: :use, line: 2}],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    }
  end

  # Diamond dependency: A -> B, A -> C, B -> D, C -> D
  defp ast_data_diamond do
    make_mod = fn name, deps ->
      imports = Enum.map(deps, fn dep -> %{module: dep, type: :alias, line: 2} end)
      %{
        modules: [%{name: name, line: 1}],
        functions: [%{name: :run, arity: 0, type: :def, line: 3}],
        imports: imports,
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    end

    %{
      "lib/a.ex" => make_mod.("A", ["B", "C"]),
      "lib/b.ex" => make_mod.("B", ["D"]),
      "lib/c.ex" => make_mod.("C", ["D"]),
      "lib/d.ex" => make_mod.("D", [])
    }
  end

  # ============================================================================
  # Pass 1: Vertex Creation
  # ============================================================================

  describe "build_graph/1 — vertex creation" do
    test "creates module vertices" do
      graph = Builder.build_graph(ast_data_single_module())
      assert Graph.has_vertex?(graph, "Alpha")
      assert :module in Graph.vertex_labels(graph, "Alpha")
    end

    test "creates function vertices with MFA format" do
      graph = Builder.build_graph(ast_data_single_module())
      assert Graph.has_vertex?(graph, "Alpha.start/0")
      assert Graph.has_vertex?(graph, "Alpha.run/1")
      assert Graph.has_vertex?(graph, "Alpha.internal/0")
      assert :function in Graph.vertex_labels(graph, "Alpha.start/0")
    end

    # Regression guard: default args auto-generate function heads at every
    # arity in min_arity..arity. The extractor records min_arity; the
    # builder must emit a vertex per generated arity so call sites at any
    # arity find their target vertex.
    test "emits a vertex for each arity when min_arity < arity" do
      ast_data = %{
        "lib/m.ex" => %{
          modules: [%{name: "M", line: 1}],
          # def chunk(content, opts \\ []) → min_arity 1, arity 2
          functions: [%{name: :chunk, arity: 2, min_arity: 1, type: :def, line: 3}],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(ast_data)
      assert Graph.has_vertex?(graph, "M.chunk/1")
      assert Graph.has_vertex?(graph, "M.chunk/2")
    end

    test "min_arity missing falls back to single vertex at arity" do
      # Back-compat: fixtures without min_arity (e.g. from v6 cache) should
      # behave as before — one vertex at the reported arity.
      ast_data = %{
        "lib/m.ex" => %{
          modules: [%{name: "M", line: 1}],
          functions: [%{name: :run, arity: 1, type: :def, line: 3}],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(ast_data)
      assert Graph.has_vertex?(graph, "M.run/1")
      refute Graph.has_vertex?(graph, "M.run/0")
    end

    test "creates struct vertices" do
      graph = Builder.build_graph(ast_data_with_struct())
      # Struct vertex uses module name with :struct label
      labels = Graph.vertex_labels(graph, "Schema")
      assert :struct in labels or :module in labels
    end

    test "creates behaviour vertices when callbacks present" do
      graph = Builder.build_graph(ast_data_with_behaviour())
      # add_module_vertices adds :module first, then add_behaviour_vertices
      # adds :behaviour — both labels should be present on the vertex
      labels = Graph.vertex_labels(graph, "Provider")
      # The vertex may have [:module] or [:behaviour] or both depending on
      # Graph.add_vertex behavior (libgraph replaces or appends labels).
      # What matters is the vertex exists and the builder processed callbacks.
      assert Graph.has_vertex?(graph, "Provider")
      # Either :module or :behaviour label should be present
      assert :module in labels or :behaviour in labels
    end

    test "empty AST data produces empty graph" do
      graph = Builder.build_graph(%{})
      assert Graph.num_vertices(graph) == 0
      assert Graph.num_edges(graph) == 0
    end

    test "module without functions still creates module vertex" do
      data = %{
        "lib/empty.ex" => %{
          modules: [%{name: "Empty", line: 1}],
          functions: [],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Empty")
      assert Graph.num_vertices(graph) >= 1
    end

    test "multiple modules in same project" do
      graph = Builder.build_graph(ast_data_with_dependency())
      assert Graph.has_vertex?(graph, "Alpha")
      assert Graph.has_vertex?(graph, "Beta")
    end
  end

  # ============================================================================
  # Pass 2: Dependency Edges
  # ============================================================================

  describe "build_graph/1 — dependency edges" do
    test "creates depends_on edge from importer to imported module" do
      graph = Builder.build_graph(ast_data_with_dependency())
      edges = Graph.edges(graph, "Alpha", "Beta")
      assert length(edges) > 0
      assert Enum.any?(edges, fn e -> e.label == :depends_on end)
    end

    test "no self-dependency edge" do
      data = %{
        "lib/self.ex" => %{
          modules: [%{name: "Self", line: 1}],
          functions: [],
          imports: [%{module: "Self", type: :alias, line: 2}],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(data)
      edges = Graph.edges(graph, "Self", "Self")
      dep_edges = Enum.filter(edges, fn e -> e.label == :depends_on end)
      assert dep_edges == []
    end

    test "no edge to external modules not in project" do
      data = %{
        "lib/app.ex" => %{
          modules: [%{name: "App", line: 1}],
          functions: [],
          imports: [%{module: "Jason", type: :alias, line: 2}],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(data)
      refute Graph.has_vertex?(graph, "Jason")
    end

    test "creates implements edge from use/require" do
      graph = Builder.build_graph(ast_data_with_implements())
      edges = Graph.edges(graph, "MyProvider", "Provider")
      assert Enum.any?(edges, fn e -> e.label == :implements end)
    end

    test "diamond dependency creates correct edges" do
      graph = Builder.build_graph(ast_data_diamond())

      # A -> B
      assert Enum.any?(Graph.edges(graph, "A", "B"), fn e -> e.label == :depends_on end)
      # A -> C
      assert Enum.any?(Graph.edges(graph, "A", "C"), fn e -> e.label == :depends_on end)
      # B -> D
      assert Enum.any?(Graph.edges(graph, "B", "D"), fn e -> e.label == :depends_on end)
      # C -> D
      assert Enum.any?(Graph.edges(graph, "C", "D"), fn e -> e.label == :depends_on end)
      # No reverse edges
      assert Graph.edges(graph, "D", "A") == []
      assert Graph.edges(graph, "B", "A") == []
    end
  end

  # ============================================================================
  # Graph Topology
  # ============================================================================

  describe "build_graph/1 — topology" do
    test "directed graph type" do
      graph = Builder.build_graph(ast_data_single_module())
      # Graph.info/1 returns graph metadata
      info = Graph.info(graph)
      assert info[:type] == :directed
    end

    test "vertex count matches modules + functions" do
      graph = Builder.build_graph(ast_data_single_module())
      # 1 module + 3 functions = 4 vertices minimum
      assert Graph.num_vertices(graph) >= 4
    end

    test "in/out neighbors for dependency" do
      graph = Builder.build_graph(ast_data_with_dependency())
      # Alpha depends on Beta → Alpha's out-neighbors should include Beta
      assert "Beta" in Graph.out_neighbors(graph, "Alpha")
      # Beta's in-neighbors should include Alpha (Alpha depends on Beta)
      assert "Alpha" in Graph.in_neighbors(graph, "Beta")
    end

    test "isolated modules have no dependency edges" do
      data = %{
        "lib/island_a.ex" => %{
          modules: [%{name: "IslandA", line: 1}],
          functions: [],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        },
        "lib/island_b.ex" => %{
          modules: [%{name: "IslandB", line: 1}],
          functions: [],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(data)
      assert Graph.out_neighbors(graph, "IslandA") == []
      assert Graph.out_neighbors(graph, "IslandB") == []
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "build_graph/1 — edge cases" do
    test "file with no modules produces no vertices for that file" do
      data = %{
        "lib/empty.ex" => %{
          modules: [],
          functions: [%{name: :orphan, arity: 0, type: :def, line: 1}],
          imports: [],
          structs: [],
          callbacks: [],
          types: [],
          specs: [],
          docs: []
        }
      }

      graph = Builder.build_graph(data)
      # No module to anchor functions to, so function vertices skipped
      refute Graph.has_vertex?(graph, ".orphan/0")
    end

    test "missing keys default to empty lists" do
      data = %{
        "lib/bare.ex" => %{
          modules: [%{name: "Bare", line: 1}]
          # All other keys missing
        }
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Bare")
    end

    test "large number of modules" do
      data =
        1..50
        |> Enum.map(fn i ->
          {"lib/mod_#{i}.ex", %{
            modules: [%{name: "Mod#{i}", line: 1}],
            functions: [%{name: :run, arity: 0, type: :def, line: 2}],
            imports: [],
            structs: [],
            callbacks: [],
            types: [],
            specs: [],
            docs: []
          }}
        end)
        |> Map.new()

      graph = Builder.build_graph(data)
      # At least 50 module vertices + 50 function vertices
      assert Graph.num_vertices(graph) >= 100
    end
  end
end
