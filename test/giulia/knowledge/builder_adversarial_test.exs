defmodule Giulia.Knowledge.BuilderAdversarialTest do
  @moduledoc """
  Adversarial tests for Knowledge.Builder — pure graph construction.

  Builder.build_graph/1 takes AST data maps and constructs a directed graph
  through 4 passes: vertices, dependency edges, xref edges, function-call edges.

  Targets:
  - Nil/missing values in AST data maps
  - Empty strings as module/function names
  - Duplicate modules across files
  - Multiple modules per file (only first gets functions)
  - Circular dependencies (A→B→A)
  - Self-referencing imports
  - Non-existent files in AST data (Pass 4 file read)
  - Very large graphs (100+ modules)
  - Module names with special characters
  - Functions with zero or extremely high arity
  - Struct and callback edge cases
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Builder

  # Helper to build minimal valid AST data for a module
  defp make_module(name, opts \\ []) do
    functions = Keyword.get(opts, :functions, [])
    imports = Keyword.get(opts, :imports, [])
    structs = Keyword.get(opts, :structs, [])
    callbacks = Keyword.get(opts, :callbacks, [])

    %{
      modules: [%{name: name, line: 1}],
      functions: functions,
      imports: imports,
      structs: structs,
      callbacks: callbacks,
      types: [],
      specs: [],
      docs: []
    }
  end

  # ============================================================================
  # 1. Nil and missing values in AST data
  # ============================================================================

  describe "nil values in AST data" do
    test "nil modules list does not crash" do
      data = %{"lib/nil.ex" => %{modules: nil, functions: [], imports: []}}
      graph = Builder.build_graph(data)
      assert Graph.num_vertices(graph) >= 0
    end

    test "nil functions list does not crash" do
      data = %{"lib/nil.ex" => %{modules: [%{name: "NilFns", line: 1}], functions: nil, imports: []}}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "NilFns")
    end

    test "nil imports list does not crash" do
      data = %{"lib/nil.ex" => %{modules: [%{name: "NilImps", line: 1}], functions: [], imports: nil}}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "NilImps")
    end

    test "nil structs list does not crash" do
      data = %{"lib/nil.ex" => %{modules: [%{name: "NilStr", line: 1}], structs: nil}}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "NilStr")
    end

    test "nil callbacks list does not crash" do
      data = %{"lib/nil.ex" => %{modules: [%{name: "NilCb", line: 1}], callbacks: nil}}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "NilCb")
    end

    test "completely empty AST data map for a file" do
      data = %{"lib/empty.ex" => %{}}
      graph = Builder.build_graph(data)
      assert Graph.num_vertices(graph) >= 0
    end

    test "AST data with only modules key" do
      data = %{"lib/bare.ex" => %{modules: [%{name: "Bare", line: 1}]}}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Bare")
    end
  end

  # ============================================================================
  # 2. Empty and special-character module names
  # ============================================================================

  describe "module name edge cases" do
    test "empty string module name" do
      data = %{"lib/empty_name.ex" => make_module("")}
      graph = Builder.build_graph(data)
      # Empty string is technically a valid vertex
      assert Graph.has_vertex?(graph, "")
    end

    test "module name with dots (nested module)" do
      data = %{"lib/nested.ex" => make_module("Giulia.Core.PathSandbox")}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Giulia.Core.PathSandbox")
    end

    test "module name with unicode" do
      data = %{"lib/unicode.ex" => make_module("Модуль")}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Модуль")
    end

    test "module name with special chars" do
      data = %{"lib/special.ex" => make_module("My-Module.v2")}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "My-Module.v2")
    end

    test "very long module name" do
      long_name = String.duplicate("A", 10_000)
      data = %{"lib/long.ex" => make_module(long_name)}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, long_name)
    end
  end

  # ============================================================================
  # 3. Duplicate modules across files
  # ============================================================================

  describe "duplicate modules" do
    test "same module name in two files" do
      data = %{
        "lib/a.ex" => make_module("Dup", functions: [%{name: :foo, arity: 0, type: :def, line: 2}]),
        "lib/b.ex" => make_module("Dup", functions: [%{name: :bar, arity: 0, type: :def, line: 2}])
      }

      graph = Builder.build_graph(data)
      # Module vertex should exist (added twice, same key)
      assert Graph.has_vertex?(graph, "Dup")
      # Both functions should exist
      assert Graph.has_vertex?(graph, "Dup.foo/0")
      assert Graph.has_vertex?(graph, "Dup.bar/0")
    end

    test "same function in duplicate module" do
      data = %{
        "lib/a.ex" => make_module("Dup", functions: [%{name: :run, arity: 0, type: :def, line: 2}]),
        "lib/b.ex" => make_module("Dup", functions: [%{name: :run, arity: 0, type: :def, line: 2}])
      }

      graph = Builder.build_graph(data)
      # Function vertex added twice with same key — should not crash
      assert Graph.has_vertex?(graph, "Dup.run/0")
    end
  end

  # ============================================================================
  # 4. Multiple modules per file
  # ============================================================================

  describe "multiple modules per file" do
    test "only first module gets function vertices" do
      data = %{
        "lib/multi.ex" => %{
          modules: [
            %{name: "First", line: 1},
            %{name: "Second", line: 20}
          ],
          functions: [%{name: :run, arity: 0, type: :def, line: 3}],
          imports: [],
          structs: [],
          callbacks: []
        }
      }

      graph = Builder.build_graph(data)
      # Both module vertices should exist
      assert Graph.has_vertex?(graph, "First")
      assert Graph.has_vertex?(graph, "Second")
      # Function anchored to first module only
      assert Graph.has_vertex?(graph, "First.run/0")
      refute Graph.has_vertex?(graph, "Second.run/0")
    end

    test "empty modules list means no function vertices" do
      data = %{
        "lib/nmod.ex" => %{
          modules: [],
          functions: [%{name: :orphan, arity: 0, type: :def, line: 1}],
          imports: [],
          structs: [],
          callbacks: []
        }
      }

      graph = Builder.build_graph(data)
      refute Graph.has_vertex?(graph, ".orphan/0")
    end
  end

  # ============================================================================
  # 5. Circular dependencies
  # ============================================================================

  describe "circular dependencies" do
    test "A depends on B, B depends on A" do
      data = %{
        "lib/a.ex" => make_module("CycA", imports: [%{module: "CycB", type: :alias, line: 2}]),
        "lib/b.ex" => make_module("CycB", imports: [%{module: "CycA", type: :alias, line: 2}])
      }

      graph = Builder.build_graph(data)
      # Both edges should exist
      assert Enum.any?(Graph.edges(graph, "CycA", "CycB"), & &1.label == :depends_on)
      assert Enum.any?(Graph.edges(graph, "CycB", "CycA"), & &1.label == :depends_on)
    end

    test "self-import creates no edge" do
      data = %{
        "lib/self.ex" => make_module("SelfRef", imports: [%{module: "SelfRef", type: :alias, line: 2}])
      }

      graph = Builder.build_graph(data)
      assert Graph.edges(graph, "SelfRef", "SelfRef") == []
    end

    test "three-way cycle A→B→C→A" do
      data = %{
        "lib/a.ex" => make_module("CyA", imports: [%{module: "CyB", type: :alias, line: 2}]),
        "lib/b.ex" => make_module("CyB", imports: [%{module: "CyC", type: :alias, line: 2}]),
        "lib/c.ex" => make_module("CyC", imports: [%{module: "CyA", type: :alias, line: 2}])
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "CyA")
      assert Graph.has_vertex?(graph, "CyB")
      assert Graph.has_vertex?(graph, "CyC")
      # All three cycle edges
      assert Enum.any?(Graph.edges(graph, "CyA", "CyB"), & &1.label == :depends_on)
      assert Enum.any?(Graph.edges(graph, "CyB", "CyC"), & &1.label == :depends_on)
      assert Enum.any?(Graph.edges(graph, "CyC", "CyA"), & &1.label == :depends_on)
    end
  end

  # ============================================================================
  # 6. Import edge cases
  # ============================================================================

  describe "import edge cases" do
    test "import of non-existent module creates no edge" do
      data = %{
        "lib/orphan.ex" => make_module("Orphan", imports: [%{module: "Ghost", type: :alias, line: 2}])
      }

      graph = Builder.build_graph(data)
      refute Graph.has_vertex?(graph, "Ghost")
      assert Graph.num_edges(graph) == 0
    end

    test "multiple import types for same module" do
      data = %{
        "lib/multi_imp.ex" => make_module("MultiImp", imports: [
          %{module: "Target", type: :alias, line: 2},
          %{module: "Target", type: :import, line: 3},
          %{module: "Target", type: :use, line: 4}
        ]),
        "lib/target.ex" => make_module("Target")
      }

      graph = Builder.build_graph(data)
      # Should have dependency edges (may have duplicates depending on Graph behavior)
      edges = Graph.edges(graph, "MultiImp", "Target")
      assert length(edges) > 0
    end

    test "use import creates implements edge" do
      data = %{
        "lib/behaviour.ex" => make_module("MyBehaviour", callbacks: [%{function: :run, arity: 0, line: 3}]),
        "lib/impl.ex" => make_module("MyImpl", imports: [%{module: "MyBehaviour", type: :use, line: 2}])
      }

      graph = Builder.build_graph(data)
      impl_edges = Graph.edges(graph, "MyImpl", "MyBehaviour")
      assert Enum.any?(impl_edges, & &1.label == :implements)
    end
  end

  # ============================================================================
  # 7. Function vertex edge cases
  # ============================================================================

  describe "function vertex edge cases" do
    test "function with arity 0" do
      data = %{"lib/f.ex" => make_module("F", functions: [%{name: :zero, arity: 0, type: :def, line: 2}])}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "F.zero/0")
    end

    test "function with high arity" do
      data = %{"lib/f.ex" => make_module("F", functions: [%{name: :many, arity: 255, type: :def, line: 2}])}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "F.many/255")
    end

    test "multiple functions same name different arity" do
      data = %{"lib/f.ex" => make_module("F", functions: [
        %{name: :run, arity: 0, type: :def, line: 2},
        %{name: :run, arity: 1, type: :def, line: 5},
        %{name: :run, arity: 2, type: :def, line: 8}
      ])}
      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "F.run/0")
      assert Graph.has_vertex?(graph, "F.run/1")
      assert Graph.has_vertex?(graph, "F.run/2")
    end

    test "def and defp with same name/arity" do
      data = %{"lib/f.ex" => make_module("F", functions: [
        %{name: :work, arity: 1, type: :def, line: 2},
        %{name: :work, arity: 1, type: :defp, line: 5}
      ])}
      graph = Builder.build_graph(data)
      # Same vertex key "F.work/1" — added twice but same vertex
      assert Graph.has_vertex?(graph, "F.work/1")
    end
  end

  # ============================================================================
  # 8. Struct and behaviour edge cases
  # ============================================================================

  describe "struct and behaviour edge cases" do
    test "module is both struct and behaviour" do
      data = %{
        "lib/dual.ex" => make_module("Dual",
          structs: [%{module: "Dual", fields: [:x], line: 3}],
          callbacks: [%{function: :run, arity: 0, line: 5}]
        )
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Dual")
      labels = Graph.vertex_labels(graph, "Dual")
      # Should have at least one of the labels
      assert length(labels) > 0
    end

    test "struct without module vertex" do
      # Struct references a module name that doesn't exist as a module vertex
      data = %{
        "lib/orphan_struct.ex" => %{
          modules: [],
          functions: [],
          imports: [],
          structs: [%{module: "OrphanStruct", fields: [:x], line: 1}],
          callbacks: []
        }
      }

      graph = Builder.build_graph(data)
      # Struct vertex should still be created even without module vertex
      assert Graph.has_vertex?(graph, "OrphanStruct")
    end

    test "behaviour with no implementers" do
      data = %{
        "lib/lonely.ex" => make_module("LonelyBehaviour",
          callbacks: [%{function: :connect, arity: 1, line: 3}]
        )
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "LonelyBehaviour")
      # No implements edges
      assert Graph.in_neighbors(graph, "LonelyBehaviour") == []
    end
  end

  # ============================================================================
  # 9. Non-existent files (Pass 4 function call edges)
  # ============================================================================

  describe "non-existent files in Pass 4" do
    test "file path does not exist on disk — no crash" do
      data = %{
        "/nonexistent/path/foo.ex" => make_module("Ghost",
          functions: [%{name: :run, arity: 0, type: :def, line: 2}]
        )
      }

      graph = Builder.build_graph(data)
      # Should have module and function vertices from Pass 1
      assert Graph.has_vertex?(graph, "Ghost")
      assert Graph.has_vertex?(graph, "Ghost.run/0")
      # Pass 4 silently skips unreadable files
    end
  end

  # ============================================================================
  # 10. Large graph stress test
  # ============================================================================

  describe "large graph" do
    test "200 modules with chain dependencies" do
      data =
        0..199
        |> Enum.map(fn i ->
          imports = if i > 0, do: [%{module: "Mod#{i - 1}", type: :alias, line: 2}], else: []
          {"lib/mod_#{i}.ex", make_module("Mod#{i}",
            functions: [%{name: :run, arity: 0, type: :def, line: 3}],
            imports: imports
          )}
        end)
        |> Map.new()

      graph = Builder.build_graph(data)
      # At least 200 module + 200 function vertices
      assert Graph.num_vertices(graph) >= 400
      # Chain: Mod1→Mod0, Mod2→Mod1, ..., Mod199→Mod198
      assert Graph.num_edges(graph) >= 199
    end

    test "fully connected graph of 20 modules" do
      modules = Enum.map(0..19, & "FC#{&1}")

      data =
        modules
        |> Enum.map(fn name ->
          others = Enum.reject(modules, & &1 == name)
          imports = Enum.map(others, fn other -> %{module: other, type: :alias, line: 2} end)
          {"lib/#{name}.ex", make_module(name, imports: imports)}
        end)
        |> Map.new()

      graph = Builder.build_graph(data)
      assert Graph.num_vertices(graph) >= 20
      # 20 * 19 = 380 dependency edges
      dep_edges = Graph.edges(graph) |> Enum.filter(& &1.label == :depends_on)
      assert length(dep_edges) == 20 * 19
    end
  end

  # ============================================================================
  # 11. xref resilience (Pass 3)
  # ============================================================================

  describe "xref resilience" do
    test "build_graph works even without BEAM directory" do
      # When no BEAM files exist, Pass 3 should silently skip
      data = %{
        "lib/a.ex" => make_module("NoBeam",
          functions: [%{name: :hello, arity: 0, type: :def, line: 2}]
        )
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "NoBeam")
      assert Graph.has_vertex?(graph, "NoBeam.hello/0")
    end
  end

  # ============================================================================
  # 12. Mixed valid and invalid entries
  # ============================================================================

  describe "mixed valid and invalid AST data" do
    test "one valid and one empty file" do
      data = %{
        "lib/valid.ex" => make_module("Valid", functions: [%{name: :ok, arity: 0, type: :def, line: 2}]),
        "lib/empty.ex" => %{}
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Valid")
      assert Graph.has_vertex?(graph, "Valid.ok/0")
    end

    test "one valid and one with nil modules" do
      data = %{
        "lib/valid.ex" => make_module("Valid2"),
        "lib/nil.ex" => %{modules: nil, functions: nil, imports: nil}
      }

      graph = Builder.build_graph(data)
      assert Graph.has_vertex?(graph, "Valid2")
    end
  end
end
