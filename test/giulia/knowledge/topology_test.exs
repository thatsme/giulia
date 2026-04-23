defmodule Giulia.Knowledge.TopologyTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Topology

  setup do
    # Build a small directed graph:
    #   A -> B -> C
    #   A -> D
    #   D -> C
    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("A", :module)
      |> Graph.add_vertex("B", :module)
      |> Graph.add_vertex("C", :module)
      |> Graph.add_vertex("D", :module)
      |> Graph.add_vertex("A.func/1", :function)
      |> Graph.add_edge("A", "B")
      |> Graph.add_edge("B", "C")
      |> Graph.add_edge("A", "D")
      |> Graph.add_edge("D", "C")
      |> Graph.add_edge("A.func/1", "B")

    %{graph: graph}
  end

  # ============================================================================
  # stats/1
  # ============================================================================

  describe "stats/1" do
    test "returns vertex and edge counts", %{graph: graph} do
      result = Topology.stats(graph)
      assert result.vertices == 5
      assert result.edges == 5
      assert is_integer(result.components)
    end

    test "counts type categories", %{graph: graph} do
      result = Topology.stats(graph)
      assert result.type_counts.modules == 4
      assert result.type_counts.functions == 1
    end

    test "identifies hubs by degree", %{graph: graph} do
      result = Topology.stats(graph)
      assert is_list(result.hubs)
      # A has most connections (out to B, D + function edge)
      hub_names = Enum.map(result.hubs, fn {name, _degree} -> name end)
      assert "A" in hub_names or "C" in hub_names
    end

    test "handles empty graph" do
      result = Topology.stats(Graph.new(type: :directed))
      assert result.vertices == 0
      assert result.edges == 0
    end
  end

  # ============================================================================
  # centrality/2
  # ============================================================================

  describe "centrality/2" do
    test "returns in/out degree", %{graph: graph} do
      {:ok, c} = Topology.centrality(graph, "C")
      # C has 2 incoming (B, D), 0 outgoing
      assert c.in_degree == 2
      assert c.out_degree == 0
    end

    test "returns error for missing vertex", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.centrality(graph, "Z")
    end
  end

  # ============================================================================
  # dependents/2 and dependencies/2
  # ============================================================================

  describe "dependents/2" do
    test "returns who depends on the module", %{graph: graph} do
      {:ok, deps} = Topology.dependents(graph, "C")
      assert "B" in deps
      assert "D" in deps
    end

    test "returns error for missing module", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.dependents(graph, "Z")
    end
  end

  describe "dependencies/2" do
    test "returns what the module depends on", %{graph: graph} do
      {:ok, deps} = Topology.dependencies(graph, "A")
      assert "B" in deps
      assert "D" in deps
    end

    test "returns empty for leaf module", %{graph: graph} do
      {:ok, deps} = Topology.dependencies(graph, "C")
      assert deps == []
    end
  end

  # ============================================================================
  # impact_map/3
  # ============================================================================

  describe "impact_map/3" do
    test "returns upstream and downstream", %{graph: graph} do
      {:ok, result} = Topology.impact_map(graph, "B", 2)
      assert result.vertex == "B"

      upstream_names = Enum.map(result.upstream, fn {name, _depth} -> name end)
      downstream_names = Enum.map(result.downstream, fn {name, _depth} -> name end)

      # B depends on C (upstream = outgoing)
      assert "C" in upstream_names
      # A depends on B (downstream = incoming)
      assert "A" in downstream_names
    end

    test "respects depth limit", %{graph: graph} do
      {:ok, result} = Topology.impact_map(graph, "A", 1)
      upstream_names = Enum.map(result.upstream, fn {name, _depth} -> name end)
      # At depth 1, A -> B and A -> D, but not C (depth 2)
      assert "B" in upstream_names
      assert "D" in upstream_names
      refute "C" in upstream_names
    end

    test "returns fuzzy matches for missing vertex", %{graph: graph} do
      {:error, {:not_found, "Z", matches, info}} = Topology.impact_map(graph, "Z", 2)
      assert is_list(matches)
      assert is_map(info)
    end
  end

  # ============================================================================
  # trace_path/3
  # ============================================================================

  describe "trace_path/3" do
    test "finds shortest path", %{graph: graph} do
      {:ok, path} = Topology.trace_path(graph, "A", "C")
      assert is_list(path)
      assert hd(path) == "A"
      assert List.last(path) == "C"
    end

    test "returns :no_path when unreachable", %{graph: graph} do
      {:ok, :no_path} = Topology.trace_path(graph, "C", "A")
    end

    test "returns error for missing source", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.trace_path(graph, "Z", "A")
    end

    test "returns error for missing target", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.trace_path(graph, "A", "Z")
    end
  end

  # ============================================================================
  # cycles/1
  # ============================================================================

  describe "cycles/1" do
    test "returns empty for acyclic graph", %{graph: graph} do
      {:ok, result} = Topology.cycles(graph)
      assert result.count == 0
      assert result.cycles == []
    end

    test "detects cycles" do
      cyclic =
        Graph.new(type: :directed)
        |> Graph.add_vertex("X", :module)
        |> Graph.add_vertex("Y", :module)
        |> Graph.add_edge("X", "Y")
        |> Graph.add_edge("Y", "X")

      {:ok, result} = Topology.cycles(cyclic)
      assert result.count == 1
      assert length(hd(result.cycles)) == 2
    end
  end

  # ============================================================================
  # fuzzy_score/2 — filter-accountability
  #
  # Scoring tiers: 100 (exact), 50 (substring), 30 (last-segment match),
  # 10 (any segment overlap), 0 (no match). `fuzzy_score/2` drives the
  # "did you mean?" suggestion list in `impact_map/3` when the requested
  # vertex is missing, so silent over-match here surfaces as garbage
  # suggestions. Helpers (`last_segment_match?/2`, `segments_overlap?/2`)
  # were exposed `@doc false` alongside `fuzzy_score/2` for test
  # harnessing.
  # ============================================================================

  describe "fuzzy_score/2 — drop-side accountability" do
    # Each fixture is {haystack, needle, expected_score}. The haystacks
    # are pre-downcased because `impact_map/3` downcases both sides
    # before scoring.
    @drop_fixtures [
      {"giulia.knowledge.topology", "giulia.knowledge.topology", 100},
      {"giulia.knowledge.topology", "topology", 50},
      {"giulia.knowledge.topology", "knowledge", 50},
      {"giulia.knowledge.topology", "giulia", 50},
      {"foo.bar.baz", "bar", 50},
      # Last-segment match requires identical (or bidirectional
      # substring) final segments.
      {"foo.bar", "quux.bar", 30},
      {"alpha.beta.gamma", "x.y.gamma", 30},
      # Shared middle segment — only segments_overlap fires.
      {"foo.bar", "bar.quux", 10},
      {"alpha.beta.gamma", "x.gamma.y", 10}
    ]

    for {haystack, needle, expected} <- @drop_fixtures do
      @tag haystack: haystack, needle: needle
      test "scores #{inspect(needle)} vs #{inspect(haystack)} as #{expected}",
           %{haystack: haystack, needle: needle} do
        assert Topology.fuzzy_score(haystack, needle) == unquote(expected),
               "fuzzy_score(#{inspect(haystack)}, #{inspect(needle)}) produced " <>
                 inspect(Topology.fuzzy_score(haystack, needle)) <>
                 " — expected #{unquote(expected)}"
      end
    end
  end

  describe "fuzzy_score/2 — pass-through accountability" do
    # Each fixture is {haystack, needle}. Must score 0 — no match of any
    # tier. Pathological cases are the silent-over-match bait: a naive
    # `String.contains?(haystack, "")` returns true for any haystack
    # (empty string is a substring of every string), so an empty needle
    # would wrongly score 50 and poison the top-5 fuzzy suggestion list
    # with arbitrary modules.
    @pass_through_fixtures [
      # Completely unrelated tokens — baseline sanity.
      {"foo", "xyz"},
      {"alpha", "beta"},
      {"enum", "registry"},
      {"mymod.foo", "otherns.bar"},
      # No shared segments, no substring, no last-segment overlap.
      {"a.b.c", "x.y.z"},
      {"alpha.beta", "gamma.delta"},
      # Disjoint despite shared initial letters.
      {"store", "search"},
      {"router", "repository"},
      {"indexer", "inspector"},
      # PATHOLOGICAL: empty needle. `String.contains?(x, "") == true`
      # would wrongly return score 50 for any haystack. An empty needle
      # is never a meaningful query.
      {"any.module", ""},
      {"foo", ""},
      {"alpha.beta.gamma", ""}
    ]

    for {haystack, needle} <- @pass_through_fixtures do
      @tag haystack: haystack, needle: needle
      test "scores 0 for #{inspect(needle)} vs #{inspect(haystack)}",
           %{haystack: haystack, needle: needle} do
        assert Topology.fuzzy_score(haystack, needle) == 0,
               "fuzzy_score(#{inspect(haystack)}, #{inspect(needle)}) wrongly scored " <>
                 inspect(Topology.fuzzy_score(haystack, needle)) <>
                 " — pass-through fixture should score 0"
      end
    end

    test "pass-through fixtures outnumber drop fixtures" do
      assert length(@pass_through_fixtures) > length(@drop_fixtures)
    end
  end

  describe "last_segment_match?/2 — accountability" do
    # Last-segment matches are bidirectional substring checks on the
    # final `.`-delimited segments. Documents the intentional fuzziness
    # (e.g. `B` ⊆ `BarBaz` produces a match) and guards against
    # empty-needle over-match.
    test "matches identical last segments" do
      assert Topology.last_segment_match?("foo.bar", "baz.bar")
    end

    test "matches when one last segment contains the other" do
      assert Topology.last_segment_match?("foo.bar", "baz.barbaz")
    end

    test "does not match unrelated last segments" do
      refute Topology.last_segment_match?("foo.bar", "foo.baz")
    end

    test "does not match on empty needle" do
      # `String.contains?(last_h, "") == true` would make any module
      # match. Pin the fixed behavior.
      refute Topology.last_segment_match?("foo.bar", "")
      refute Topology.last_segment_match?("anything", "")
    end
  end

  describe "segments_overlap?/2 — accountability" do
    test "matches on any shared segment (bidirectional substring)" do
      assert Topology.segments_overlap?("foo.bar.baz", "quux.bar.corge")
    end

    test "matches when a segment is a substring of another segment" do
      # "bar" as a segment is a substring of "barbaz" — documented
      # bidirectional behavior of the fuzzy matcher.
      assert Topology.segments_overlap?("foo.bar", "x.barbaz")
    end

    test "does not match completely disjoint segment sets" do
      refute Topology.segments_overlap?("alpha.beta", "gamma.delta")
    end

    test "does not match on empty needle" do
      refute Topology.segments_overlap?("foo.bar", "")
      refute Topology.segments_overlap?("a.b.c", "")
    end
  end

  # ============================================================================
  # get_function_edges/2 via impact_map/3 — filter-accountability
  #
  # `get_function_edges/2` keeps only vertices `String.starts_with?(v,
  # module_name <> ".")` that are labeled `:function`. Prefix matching
  # on raw strings is the same shape that bit `Indexer.ignored?/1` —
  # worth pinning the boundary cases explicitly.
  # ============================================================================

  describe "impact_map/3 function_edges — drop/pass accountability" do
    setup do
      # Graph with modules `Foo` and `FooBar`, each with one function.
      # Key test: `Foo`'s function edges must NOT include FooBar's
      # functions even though "FooBar.qux" starts with "Foo".
      graph =
        Graph.new(type: :directed)
        |> Graph.add_vertex("Foo", :module)
        |> Graph.add_vertex("FooBar", :module)
        |> Graph.add_vertex("Foo.bar/1", :function)
        |> Graph.add_vertex("Foo.baz/0", :function)
        |> Graph.add_vertex("FooBar.qux/2", :function)
        |> Graph.add_edge("Foo.bar/1", "FooBar")
        |> Graph.add_edge("FooBar.qux/2", "Foo")

      %{graph: graph}
    end

    test "keeps function vertices belonging to the module", %{graph: graph} do
      {:ok, result} = Topology.impact_map(graph, "Foo", 1)
      short_names = Enum.map(result.function_edges, fn {name, _targets} -> name end)
      assert "bar/1" in short_names
    end

    test "excludes function vertices from sibling modules sharing a prefix",
         %{graph: graph} do
      # "FooBar.qux/2" starts with "Foo" but NOT with "Foo." — the
      # `"."` separator in the prefix is what makes this safe. Pinning
      # the assertion guards against a regression that would drop the
      # dot and over-match sibling modules.
      {:ok, result} = Topology.impact_map(graph, "Foo", 1)
      short_names = Enum.map(result.function_edges, fn {name, _targets} -> name end)
      refute "qux/2" in short_names
    end

    test "excludes function vertices with no outgoing edges", %{graph: graph} do
      # "Foo.baz/0" has no out-neighbors, so the filter's final
      # `Enum.reject(&(targets == []))` step must drop it.
      {:ok, result} = Topology.impact_map(graph, "Foo", 1)
      short_names = Enum.map(result.function_edges, fn {name, _targets} -> name end)
      refute "baz/0" in short_names
    end
  end
end
