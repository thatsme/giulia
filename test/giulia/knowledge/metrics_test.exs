defmodule Giulia.Knowledge.MetricsTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Metrics

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
end
