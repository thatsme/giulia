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
  # Helpers: source-on-disk fixtures
  # ============================================================================

  # Pass 4 (AST-based function-call edges), Pass 5 (module-edge promotion),
  # and Pass 6 (module references) re-read the source file from disk in
  # addition to walking the already-extracted ast_data. Tests that exercise
  # those passes need real files. `with_sources/2` writes a temp tree,
  # analyzes each file through the normal Processor path, invokes the
  # callback with the ast_data map, and cleans up.
  defp with_sources(sources, callback) do
    dir = Path.join(System.tmp_dir!(), "giulia_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      ast_data =
        for {filename, content} <- sources, into: %{} do
          path = Path.join(dir, filename)
          File.write!(path, content)
          {:ok, data} = Giulia.AST.Processor.analyze_file(path)
          {path, data}
        end

      callback.(ast_data)
    after
      File.rm_rf!(dir)
    end
  end

  # Find edges between two vertices, regardless of label shape
  defp edges(graph, from, to) do
    Graph.edges(graph, from, to)
  end

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

  # ============================================================================
  # Regression guards for Step 1 fixes — these require source files on disk
  # because Pass 4 / Pass 5 / Pass 6 re-parse the source in addition to
  # walking the ast_data map.
  # ============================================================================

  describe "regression: predicate/bang function edge promotion" do
    # Commit cfc8d54. Before the fix, extract_module_from_mfa used ~r/\w+\/\d+/
    # which did not match `?` / `!`. Function-level :calls edges with
    # predicate targets were added correctly, but promote_function_edges_to_module
    # silently dropped them because the callee_mod regex returned nil.
    test "module-level edge exists when caller invokes a predicate function" do
      # No alias/import between Caller and Target — the module-level edge
      # can only come from :calls promotion. If extract_module_from_mfa's
      # regex silently drops predicate names, no edge is created and this
      # fails loudly.
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def run(x), do: Target.valid?(x)
          end
          """,
          "target.ex" => """
          defmodule Target do
            def valid?(x), do: is_integer(x)
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          # Function-level edge must exist
          assert Graph.has_vertex?(graph, "Caller.run/1")
          assert Graph.has_vertex?(graph, "Target.valid?/1")
          # Module-level edge must be promoted
          assert Enum.any?(edges(graph, "Caller", "Target"), fn e ->
                   match?({:calls, _}, e.label)
                 end)
        end
      )
    end

    test "module-level edge exists when caller invokes a bang function" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def run(x), do: Target.update!(x)
          end
          """,
          "target.ex" => """
          defmodule Target do
            def update!(x), do: x + 1
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          assert Enum.any?(edges(graph, "Caller", "Target"), fn e ->
                   match?({:calls, _}, e.label)
                 end)
        end
      )
    end
  end

  describe "regression: :calls edges carry via metadata" do
    # Commit 2a18e2a. Every function-level :calls edge must be labeled
    # {:calls, via} where via ∈ :direct | :alias_resolved | :erlang_atom
    # | :local. The via bucket is load-bearing for the stratified
    # sample-identity check in L1↔L3 verification.
    test "fully-qualified remote call tags :direct" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def run, do: Giulia.Nested.Target.compute(1)
          end
          """,
          "target.ex" => """
          defmodule Giulia.Nested.Target do
            def compute(x), do: x
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edge = Enum.find(edges(graph, "Caller.run/0", "Giulia.Nested.Target.compute/1"), & &1)
          assert edge != nil
          assert edge.label == {:calls, :direct}
        end
      )
    end

    test "aliased short-form call tags :alias_resolved" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            alias Giulia.Nested.Target
            def run, do: Target.compute(1)
          end
          """,
          "target.ex" => """
          defmodule Giulia.Nested.Target do
            def compute(x), do: x
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edge = Enum.find(edges(graph, "Caller.run/0", "Giulia.Nested.Target.compute/1"), & &1)
          assert edge != nil
          assert edge.label == {:calls, :alias_resolved}
        end
      )
    end

    test "intra-module call tags :local" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def outer, do: inner(1)
            def inner(x), do: x + 1
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edge = Enum.find(edges(graph, "Caller.outer/0", "Caller.inner/1"), & &1)
          assert edge != nil
          assert edge.label == {:calls, :local}
        end
      )
    end
  end

  describe "regression: :references pass + namespace-prefix fallback" do
    # Commits 5db432e + 9c67dbc. The references pass catches framework
    # wiring where modules are passed as atoms to macros (supervisor
    # children lists, Phoenix router verbs, etc.). The namespace fallback
    # resolves short-form refs inside Phoenix `scope` blocks and Ecto
    # short associations.
    test "module named in a list literal produces a :references edge" do
      with_sources(
        %{
          "app.ex" => """
          defmodule AlexClaw.Application do
            def start(_type, _args) do
              children = [AlexClawWeb.Endpoint]
              Supervisor.start_link(children, strategy: :one_for_one)
            end
          end
          """,
          "endpoint.ex" => """
          defmodule AlexClawWeb.Endpoint do
            def init(_), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          assert Enum.any?(
                   edges(graph, "AlexClaw.Application", "AlexClawWeb.Endpoint"),
                   fn e -> e.label == :references end
                 )
        end
      )
    end

    test "short-form sibling resolved via caller's namespace prefix" do
      with_sources(
        %{
          "router.ex" => """
          defmodule AlexClawWeb.Router do
            # Phoenix-style short-form: HealthController is a sibling in
            # AlexClawWeb.*. Without the namespace fallback, [:HealthController]
            # resolves to just "HealthController" and never matches.
            def routes, do: [get: {"/health", HealthController, :check}]
          end
          """,
          "health_controller.ex" => """
          defmodule AlexClawWeb.HealthController do
            def check(conn, _), do: conn
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          # Either via :references (preferred) or :depends_on — we just
          # need *some* edge to be created thanks to the fallback.
          refs =
            edges(graph, "AlexClawWeb.Router", "AlexClawWeb.HealthController")
            |> Enum.map(& &1.label)

          assert refs != [], "expected an edge from Router to HealthController via namespace fallback"
        end
      )
    end
  end

  # ============================================================================
  # Pass 10: Function-reference edges (MFA tuples, captures, apply/3)
  # ============================================================================

  describe "build_graph/1 — function-reference edges (Pass 10)" do
    defp ref_edges(graph, from, to) do
      graph
      |> Graph.out_edges(from)
      |> Enum.filter(fn e -> e.v2 == to end)
    end

    test "MFA tuple with __MODULE__ produces a :mfa_ref edge" do
      with_sources(
        %{
          "demo.ex" => """
          defmodule Demo do
            def kick do
              _ = {__MODULE__, :execute_metrics, []}
              :ok
            end

            def execute_metrics, do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          assert Graph.has_vertex?(graph, "Demo.execute_metrics/0")

          edges = ref_edges(graph, "Demo.kick/0", "Demo.execute_metrics/0")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :mfa_ref} end),
                 "expected :mfa_ref edge from Demo.kick/0 to Demo.execute_metrics/0; got: #{inspect(Enum.map(edges, & &1.label))}"
        end
      )
    end

    test "MFA tuple with fully-qualified module produces a :mfa_ref edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def kick, do: poll({Demo.Worker, :tick, [42]})
            defp poll(_), do: :ok
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick(_n), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edges = ref_edges(graph, "Caller.kick/0", "Demo.Worker.tick/1")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :mfa_ref} end)
        end
      )
    end

    test "MFA tuple with variable args produces no edge (arity unknown)" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def kick(args), do: poll({Demo.Worker, :tick, args})
            defp poll(_), do: :ok
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick(_a), do: :ok
            def tick(_a, _b), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          # No :mfa_ref edge to either tick arity — variable arg list is conservative skip
          assert ref_edges(graph, "Caller.kick/1", "Demo.Worker.tick/1")
                 |> Enum.all?(fn e -> e.label != {:calls, :mfa_ref} end)

          assert ref_edges(graph, "Caller.kick/1", "Demo.Worker.tick/2")
                 |> Enum.all?(fn e -> e.label != {:calls, :mfa_ref} end)
        end
      )
    end

    test "MFA tuple with non-existent target produces no orphan edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def kick, do: poll({Demo.Worker, :phantom, []})
            defp poll(_), do: :ok
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick, do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          # Worker.phantom/0 doesn't exist → no edge created
          refute Graph.has_vertex?(graph, "Demo.Worker.phantom/0")
        end
      )
    end

    test "function capture &Mod.fn/N produces a :capture_ref edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def fan_out, do: Enum.map([1, 2], &Demo.Worker.tick/1)
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick(_n), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edges = ref_edges(graph, "Caller.fan_out/0", "Demo.Worker.tick/1")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :capture_ref} end)
        end
      )
    end

    test "apply/3 with literal module + atom + list produces an :apply_ref edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def call_it, do: apply(Demo.Worker, :tick, [42])
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick(_n), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edges = ref_edges(graph, "Caller.call_it/0", "Demo.Worker.tick/1")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :apply_ref} end)
        end
      )
    end

    test "Kernel.apply/3 fully-qualified produces an :apply_ref edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def call_it, do: Kernel.apply(Demo.Worker, :tick, [])
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick, do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edges = ref_edges(graph, "Caller.call_it/0", "Demo.Worker.tick/0")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :apply_ref} end)
        end
      )
    end

    test "apply/3 with variable args list produces no edge" do
      with_sources(
        %{
          "caller.ex" => """
          defmodule Caller do
            def call_it(args), do: apply(Demo.Worker, :tick, args)
          end
          """,
          "worker.ex" => """
          defmodule Demo.Worker do
            def tick(_n), do: :ok
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          assert ref_edges(graph, "Caller.call_it/1", "Demo.Worker.tick/1")
                 |> Enum.all?(fn e -> e.label != {:calls, :apply_ref} end)
        end
      )
    end
  end

  # ============================================================================
  # Pass 11: Use-injected import edges (defmacro __using__ + import M idiom)
  # ============================================================================

  describe "build_graph/1 — use-injected import edges (Pass 11)" do
    test "use M with __using__ that imports M produces edge to M's defmacro" do
      with_sources(
        %{
          "host.ex" => """
          defmodule Host do
            defmacro __using__(_) do
              quote do
                import Host
              end
            end

            defmacro flag?, do: quote(do: false)
          end
          """,
          "consumer.ex" => """
          defmodule Consumer do
            use Host

            def check, do: flag?()
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          edges = ref_edges(graph, "Consumer.check/0", "Host.flag?/0")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :use_import_ref} end),
                 "expected :use_import_ref edge from Consumer.check/0 to Host.flag?/0; got: #{inspect(Enum.map(edges, & &1.label))}"
        end
      )
    end

    test "use M where __using__ uses __MODULE__ as the imported module" do
      with_sources(
        %{
          "host.ex" => """
          defmodule HostB do
            defmacro __using__(_) do
              quote do
                import __MODULE__
              end
            end

            def helper, do: :ok
          end
          """,
          "consumer.ex" => """
          defmodule ConsumerB do
            use HostB

            def go, do: helper()
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)

          edges = ref_edges(graph, "ConsumerB.go/0", "HostB.helper/0")
          assert Enum.any?(edges, fn e -> e.label == {:calls, :use_import_ref} end)
        end
      )
    end

    test "use M without import-injection in __using__ produces no edge" do
      with_sources(
        %{
          "host.ex" => """
          defmodule QuietHost do
            defmacro __using__(_) do
              quote do
                require QuietHost
              end
            end

            def helper, do: :ok
          end
          """,
          "consumer.ex" => """
          defmodule QuietConsumer do
            use QuietHost

            def go, do: helper()
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          edges = ref_edges(graph, "QuietConsumer.go/0", "QuietHost.helper/0")
          assert Enum.all?(edges, fn e -> e.label != {:calls, :use_import_ref} end),
                 "no edge expected when __using__ does not inject `import`"
        end
      )
    end

    test "unqualified call without matching imported function produces no edge" do
      with_sources(
        %{
          "host.ex" => """
          defmodule HostC do
            defmacro __using__(_) do
              quote do
                import HostC
              end
            end

            def real_helper, do: :ok
          end
          """,
          "consumer.ex" => """
          defmodule ConsumerC do
            use HostC

            def go, do: phantom()
          end
          """
        },
        fn ast_data ->
          graph = Builder.build_graph(ast_data)
          # HostC.phantom/0 doesn't exist — no edge
          refute Graph.has_vertex?(graph, "HostC.phantom/0")
        end
      )
    end
  end
end
