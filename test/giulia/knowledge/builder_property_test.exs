defmodule Giulia.Knowledge.BuilderPropertyTest do
  @moduledoc """
  Property-based tests for `Knowledge.Builder.build_graph/1` using
  StreamData.

  Complements the existing example-based tests (`builder_test.exs`,
  `builder_adversarial_test.exs`) by asserting structural invariants
  across a generated input space rather than specific cases. A
  regression that passes the example tests but violates a property
  here reveals a silent behaviour change that would otherwise need
  a hand-curated fixture to surface.

  Properties asserted:

    * **Determinism** — same AST input produces the same graph on
      repeated builds. Catches unintended randomness in pass
      ordering, MapSet iteration, or dict traversal.
    * **Module vertex parity** — the set of `:module`-labeled
      vertices equals the set of unique module names in the input.
      Catches dedup bugs and loss bugs.
    * **Function vertex coverage** — for every
      `{module_name, func_name, arity}` in the input (expanded
      across `min_arity..arity` for default-arg cascades), the
      graph has a matching function vertex.
    * **Vertex label sanity** — every vertex has at least one
      label from the documented set. Catches accidental unlabeled
      vertices from pass-4/5/6 edge construction.

  Generators produce synthetic AST-data maps matching the shape
  `Context.Store.all_asts/1` returns — one module per file, to
  avoid the Builder's documented "first module wins" behaviour for
  multi-module files (see `add_function_vertices/2`).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Giulia.Knowledge.Builder

  # ============================================================================
  # Generators
  # ============================================================================

  # Capitalised single-segment module name. Multi-segment names
  # introduce cross-file resolution paths that the pure Builder
  # passes treat differently — keep the input space tight so
  # properties stay about graph construction, not name parsing.
  defp module_name_gen do
    StreamData.string(?A..?Z, min_length: 1, max_length: 1)
    |> StreamData.bind(fn first_char ->
      StreamData.string(?a..?z, min_length: 0, max_length: 7)
      |> StreamData.map(fn rest -> first_char <> rest end)
    end)
  end

  defp function_info_gen do
    gen all name <-
              StreamData.member_of([
                :run,
                :handle,
                :process,
                :foo,
                :bar,
                :baz,
                :get!,
                :valid?,
                :put!,
                :has_key?
              ]),
            arity <- StreamData.integer(0..4),
            default_offset <- StreamData.integer(0..2),
            type <- StreamData.member_of([:def, :defp, :defmacro, :defdelegate]) do
      min_arity = max(0, arity - default_offset)

      %{
        name: name,
        arity: arity,
        min_arity: min_arity,
        type: type,
        line: 1,
        complexity: 0
      }
    end
  end

  defp file_ast_gen do
    gen all module_name <- module_name_gen(),
            functions <- StreamData.list_of(function_info_gen(), min_length: 0, max_length: 6) do
      %{
        modules: [%{name: module_name, line: 1, moduledoc: nil}],
        # Dedupe within a file by {name, arity} — matches how the
        # extractor deduplicates function clauses.
        functions: Enum.uniq_by(functions, fn f -> {f.name, f.arity} end),
        imports: [],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
    end
  end

  defp ast_data_gen do
    gen all files <- StreamData.list_of(file_ast_gen(), min_length: 1, max_length: 6) do
      files
      |> Enum.with_index()
      |> Map.new(fn {ast, idx} -> {"lib/file_#{idx}.ex", ast} end)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp module_vertices(graph) do
    graph
    |> Graph.vertices()
    |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)
    |> MapSet.new()
  end

  defp function_vertices(graph) do
    graph
    |> Graph.vertices()
    |> Enum.filter(fn v -> :function in Graph.vertex_labels(graph, v) end)
    |> MapSet.new()
  end

  defp unique_module_names(ast_data) do
    ast_data
    |> Enum.flat_map(fn {_path, data} -> Enum.map(data[:modules] || [], & &1.name) end)
    |> MapSet.new()
  end

  defp expected_function_vertices(ast_data) do
    ast_data
    |> Enum.flat_map(fn {_path, data} ->
      case data[:modules] do
        [%{name: mod} | _] ->
          Enum.flat_map(data[:functions] || [], fn f ->
            Enum.map(f.min_arity..f.arity, fn n -> "#{mod}.#{f.name}/#{n}" end)
          end)

        _ ->
          []
      end
    end)
    |> MapSet.new()
  end

  # ============================================================================
  # Properties
  # ============================================================================

  property "build_graph/1 is deterministic — same input, same graph" do
    check all ast_data <- ast_data_gen(), max_runs: 50 do
      g1 = Builder.build_graph(ast_data)
      g2 = Builder.build_graph(ast_data)

      assert Enum.sort(Graph.vertices(g1)) == Enum.sort(Graph.vertices(g2)),
             "vertex sets diverged across two builds of the same input"

      edges_as_tuples = fn g ->
        g |> Graph.edges() |> Enum.map(fn e -> {e.v1, e.v2, e.label} end) |> Enum.sort()
      end

      assert edges_as_tuples.(g1) == edges_as_tuples.(g2),
             "edge sets diverged across two builds of the same input"
    end
  end

  property "module vertex set equals the set of unique module names in input" do
    check all ast_data <- ast_data_gen(), max_runs: 50 do
      graph = Builder.build_graph(ast_data)

      assert module_vertices(graph) == unique_module_names(ast_data),
             "module vertex set != input module-name set — dedup or loss bug"
    end
  end

  property "every expected function vertex exists in the graph" do
    check all ast_data <- ast_data_gen(), max_runs: 50 do
      graph = Builder.build_graph(ast_data)
      actual = function_vertices(graph)
      expected = expected_function_vertices(ast_data)

      # Builder may create additional function vertices for call
      # targets discovered during AST walk (Pass 4). Assert
      # `expected ⊆ actual` rather than strict equality.
      missing = MapSet.difference(expected, actual)

      assert MapSet.size(missing) == 0,
             "missing function vertices: #{inspect(MapSet.to_list(missing))}"
    end
  end

  property "every vertex carries at least one recognized label" do
    check all ast_data <- ast_data_gen(), max_runs: 50 do
      graph = Builder.build_graph(ast_data)
      recognized = MapSet.new([:module, :function, :struct, :behaviour])

      for v <- Graph.vertices(graph) do
        labels = MapSet.new(Graph.vertex_labels(graph, v))

        assert not MapSet.disjoint?(labels, recognized),
               "vertex #{inspect(v)} has no recognized label — got #{inspect(MapSet.to_list(labels))}"
      end
    end
  end
end
