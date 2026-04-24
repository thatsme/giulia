defmodule Giulia.Knowledge.MetricsTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Metrics

  describe "collect_all_calls/1 — module-stack regression" do
    # Regression for the "first module wins" bug that caused dead_code
    # to flag live same-module calls in files with multiple top-level
    # `defmodule` blocks (observed in Plausible.HTTPClient, three
    # defmodules in one file — see commit <post-11ccbd3>).
    @tmp_dir Path.join(System.tmp_dir!(), "giulia_metrics_collect_calls_test")

    setup do
      File.mkdir_p!(@tmp_dir)
      on_exit(fn -> File.rm_rf!(@tmp_dir) end)
      :ok
    end

    defp write_fixture!(filename, contents) do
      path = Path.join(@tmp_dir, filename)
      File.write!(path, contents)
      path
    end

    test "local calls are attributed to the enclosing defmodule, not the file-first module" do
      source = """
      defmodule Fixtures.First do
        def only_in_first, do: :ok
      end

      defmodule Fixtures.Second do
        def entry, do: helper(:payload)

        defp helper(x) do
          x |> transform() |> finalize()
        end

        defp transform(x), do: {:transformed, x}
        defp finalize(x), do: {:final, x}
      end
      """

      path = write_fixture!("multi_module.ex", source)

      ast_data = %{
        modules: [
          %{name: "Fixtures.First", line: 1, moduledoc: nil, impl_for: nil},
          %{name: "Fixtures.Second", line: 5, moduledoc: nil, impl_for: nil}
        ],
        imports: []
      }

      calls = Metrics.collect_all_calls(%{path => ast_data})

      # The local pipe chain inside Fixtures.Second must attribute
      # to Fixtures.Second, not the file-first Fixtures.First.
      assert {"Fixtures.Second", :local, "helper", 1} in calls,
             "helper/1 local call should be under Fixtures.Second"

      assert {"Fixtures.Second", :local, "transform", 1} in calls,
             "transform/1 should be under Fixtures.Second, not First"

      assert {"Fixtures.Second", :local, "finalize", 1} in calls,
             "finalize/1 should be under Fixtures.Second, not First"

      # And must NOT be attributed to Fixtures.First (which was the
      # pre-fix behavior — file-first module grabbed every local call).
      refute {"Fixtures.First", :local, "helper", 1} in calls
      refute {"Fixtures.First", :local, "transform", 1} in calls
    end

    test "multi-segment aliases resolve through the first segment" do
      # Regression for `Ingestion.Request.build(...)` under
      # `alias Plausible.Ingestion` — the old alias map only indexed
      # single-segment shorts, so multi-segment references landed in
      # the call-set under the unresolved form and dead_code missed.
      source = """
      defmodule Caller do
        alias Plausible.Ingestion

        def run(conn), do: Ingestion.Request.build(conn)
      end
      """

      path = write_fixture!("multi_alias.ex", source)

      ast_data = %{
        modules: [%{name: "Caller", line: 1, moduledoc: nil, impl_for: nil}],
        imports: [%{module: "Plausible.Ingestion", type: :alias, line: 2}]
      }

      calls = Metrics.collect_all_calls(%{path => ast_data})

      assert {"Plausible.Ingestion.Request", "build", 1} in calls,
             "multi-segment alias must resolve first segment: " <>
               "Ingestion.Request.build → Plausible.Ingestion.Request.build"

      refute {"Ingestion.Request", "build", 1} in calls,
             "unresolved form must not appear — dead_code would miss the lookup"
    end

    test "defimpl module body gets the impl-module name on its stack" do
      # Without the stack, local calls inside `defimpl` get attributed
      # to the enclosing `defmodule` (or the file-first module). With
      # the stack, they get the Proto.Type composite name.
      source = """
      defimpl Jason.Encoder, for: SomeType do
        def encode(value, opts), do: serialize(value, opts)

        defp serialize(value, _opts), do: inspect(value)
      end
      """

      path = write_fixture!("defimpl_body.ex", source)

      ast_data = %{
        modules: [
          %{
            name: "Jason.Encoder.SomeType",
            line: 1,
            moduledoc: nil,
            impl_for: "Jason.Encoder"
          }
        ],
        imports: []
      }

      calls = Metrics.collect_all_calls(%{path => ast_data})

      assert {"Jason.Encoder.SomeType", :local, "serialize", 2} in calls,
             "serialize/2 local call inside defimpl must attribute to " <>
               "Jason.Encoder.SomeType"
    end
  end

  describe "coupling_from_calls/1" do
    test "groups call triples into coupling pairs" do
      triples = [
        {"A", "B", "foo"},
        {"A", "B", "bar"},
        {"A", "C", "baz"},
        {"C", "A", "qux"}
      ]

      {:ok, %{pairs: pairs, count: count}} = Metrics.coupling_from_calls(triples)
      assert count == 3

      ab = Enum.find(pairs, fn p -> p.caller == "A" and p.callee == "B" end)
      assert ab.call_count == 2
      assert ab.distinct_functions == 2
      assert "foo" in ab.functions
      assert "bar" in ab.functions
    end

    test "returns empty for no calls" do
      {:ok, %{pairs: [], count: 0}} = Metrics.coupling_from_calls([])
    end

    test "sorts by call_count descending" do
      triples = [
        {"A", "B", "f1"},
        {"A", "C", "f2"},
        {"A", "C", "f3"},
        {"A", "C", "f4"}
      ]

      {:ok, %{pairs: [first | _]}} = Metrics.coupling_from_calls(triples)
      assert first.callee == "C"
      assert first.call_count == 3
    end

    test "limits to 50 pairs" do
      # Generate 60 distinct pairs
      triples = for i <- 1..60, do: {"Caller", "Callee#{i}", "func"}
      {:ok, %{count: count}} = Metrics.coupling_from_calls(triples)
      assert count == 50
    end
  end

  describe "build_coupling_map_from_calls/1" do
    test "returns max coupling per caller module" do
      triples = [
        {"A", "B", "foo"},
        {"A", "B", "bar"},
        {"A", "B", "baz"},
        {"A", "C", "qux"},
        {"D", "E", "one"}
      ]

      map = Metrics.build_coupling_map_from_calls(triples)
      # A calls B 3 times, C 1 time — max is 3
      assert map["A"] == 3
      assert map["D"] == 1
    end

    test "returns empty map for no calls" do
      assert Metrics.build_coupling_map_from_calls([]) == %{}
    end

    test "handles single call per module" do
      triples = [{"X", "Y", "hello"}]
      map = Metrics.build_coupling_map_from_calls(triples)
      assert map["X"] == 1
    end
  end

  # ==========================================================================
  # Heatmap scoring formula tests
  # ==========================================================================

  describe "heatmap scoring formula" do
    test "zero inputs produce zero score" do
      score = compute_heatmap_score(0, 0, true, 0)
      assert score == 0
    end

    test "missing test adds 25-point floor penalty" do
      score = compute_heatmap_score(0, 0, false, 0)
      assert score == 25
    end

    test "max centrality (15+) saturates at 100" do
      score = compute_heatmap_score(20, 0, true, 0)
      assert score == 30
    end

    test "max complexity (200+) saturates at 100" do
      score = compute_heatmap_score(0, 300, true, 0)
      assert score == 25
    end

    test "max coupling (50+) saturates at 100" do
      score = compute_heatmap_score(0, 0, true, 80)
      assert score == 20
    end

    test "all factors maxed with no test = 100" do
      score = compute_heatmap_score(20, 300, false, 80)
      assert score == 100
    end

    test "all factors maxed with test = 75" do
      score = compute_heatmap_score(20, 300, true, 80)
      assert score == 75
    end

    test "zone boundaries" do
      assert heatmap_zone(60) == "red"
      assert heatmap_zone(59) == "yellow"
      assert heatmap_zone(30) == "yellow"
      assert heatmap_zone(29) == "green"
      assert heatmap_zone(0) == "green"
    end

    test "realistic hub module — moderate centrality, tested" do
      score = compute_heatmap_score(10, 80, true, 20)
      assert score == 37
      assert heatmap_zone(score) == "yellow"
    end
  end

  # ==========================================================================
  # Change risk scoring formula tests
  # ==========================================================================

  describe "change_risk scoring formula" do
    test "zero inputs produce zero score" do
      score = compute_change_risk(0, 0, 0, 0, 0, 0)
      assert score == 0
    end

    test "centrality acts as multiplier" do
      score_no_hub = compute_change_risk(0, 50, 0, 0, 10, 0)
      score_hub = compute_change_risk(10, 50, 0, 0, 10, 0)
      assert score_hub > score_no_hub * 5
    end

    test "complexity has 2x weight" do
      score = compute_change_risk(0, 100, 0, 0, 0, 0)
      assert score == 200
    end

    test "fan_out has 2x weight" do
      score = compute_change_risk(0, 0, 5, 0, 0, 0)
      assert score == 10
    end

    test "coupling has 2x weight" do
      score = compute_change_risk(0, 0, 0, 30, 0, 0)
      assert score == 60
    end

    test "function count is additive 1x" do
      score = compute_change_risk(0, 0, 0, 0, 20, 0)
      assert score == 20
    end

    test "realistic Context.Store-like module" do
      score = compute_change_risk(36, 28, 3, 13, 33, 33)
      assert score == 2926
    end
  end

  # ==========================================================================
  # Helpers — exact scoring formulas from metrics.ex
  # ==========================================================================

  defp compute_heatmap_score(centrality, complexity, has_test, max_coupling) do
    norm_centrality = min(centrality / 15 * 100, 100) |> trunc()
    norm_complexity = min(complexity / 200 * 100, 100) |> trunc()
    norm_test = if has_test, do: 0, else: 100
    norm_coupling = min(max_coupling / 50 * 100, 100) |> trunc()

    trunc(
      norm_centrality * 0.30 +
      norm_complexity * 0.25 +
      norm_test * 0.25 +
      norm_coupling * 0.20
    )
  end

  defp heatmap_zone(score) do
    cond do
      score >= 60 -> "red"
      score >= 30 -> "yellow"
      true -> "green"
    end
  end

  defp compute_change_risk(centrality, complexity, fan_out, max_coupling, total_funcs, public_funcs) do
    api_ratio = if total_funcs > 0, do: public_funcs / total_funcs, else: 0.0
    api_penalty = trunc(Float.round(api_ratio * total_funcs, 0))

    base =
      (complexity * 2) +
      (fan_out * 2) +
      (max_coupling * 2) +
      api_penalty +
      total_funcs

    multiplier = 1 + (centrality / 2)
    trunc(base * multiplier)
  end

  describe "called_by_unresolved_alias?/2 — macro-injected alias fallback" do
    # Regression for CustomProps.{request,response}_schema/0 on analytics-master:
    # caller files use `use PlausibleWeb, :open_api_schema` which injects
    # `alias PlausibleWeb.Plugins.API.Schemas` via the macro expansion. A
    # subsequent user-written `alias Schemas.Goal.CustomProps` resolves
    # only through the file's explicit imports, so the call-set records the
    # truncated `Schemas.Goal.CustomProps` — which never exact-matches the
    # real `PlausibleWeb.Plugins.API.Schemas.Goal.CustomProps`.
    test "exempts when recorded caller is dot-bounded suffix of full module" do
      called = MapSet.new([{"Schemas.Goal.CustomProps", "response_schema", 0}])

      func = %{
        module: "PlausibleWeb.Plugins.API.Schemas.Goal.CustomProps",
        name: :response_schema,
        arity: 0
      }

      assert Metrics.called_by_unresolved_alias?(called, func)
    end

    test "does not exempt when suffix is not dot-bounded" do
      # "Foo" is NOT a suffix of "BarFoo" under dot-boundary semantics —
      # guards against false exemption of unrelated modules that share a
      # tail word.
      called = MapSet.new([{"Foo", "bar", 0}])

      func = %{module: "BarFoo", name: :bar, arity: 0}

      refute Metrics.called_by_unresolved_alias?(called, func)
    end

    test "does not exempt on exact match — exact match is handled earlier" do
      # The helper returns false when recorded_mod == func.module because
      # that path is covered by the earlier `MapSet.member?` check and
      # returning true here would mask arity-mismatch bugs.
      called = MapSet.new([{"A.B.C", "fn", 0}])
      func = %{module: "A.B.C", name: :fn, arity: 0}

      refute Metrics.called_by_unresolved_alias?(called, func)
    end

    test "respects arity — different arity does not exempt" do
      called = MapSet.new([{"Schemas.Goal.CustomProps", "response_schema", 1}])

      func = %{
        module: "PlausibleWeb.Plugins.API.Schemas.Goal.CustomProps",
        name: :response_schema,
        arity: 0
      }

      refute Metrics.called_by_unresolved_alias?(called, func)
    end

    test "ignores :local-tagged entries — they carry full caller module" do
      # `{mod, :local, name, arity}` entries are 4-tuples; the head pattern
      # in the helper only matches 3-tuples, so they don't participate.
      called = MapSet.new([{"Schemas.Goal.CustomProps", :local, "response_schema", 0}])

      func = %{
        module: "PlausibleWeb.Plugins.API.Schemas.Goal.CustomProps",
        name: :response_schema,
        arity: 0
      }

      refute Metrics.called_by_unresolved_alias?(called, func)
    end
  end
end
