defmodule Giulia.Knowledge.ScoringConfigTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.ScoringConfig

  test "current/0 loads the JSON config and returns a map with the expected top-level keys" do
    cfg = ScoringConfig.current()

    assert is_map(cfg)
    assert Map.has_key?(cfg, :heatmap)
    assert Map.has_key?(cfg, :change_risk)
    assert Map.has_key?(cfg, :god_modules)
    assert Map.has_key?(cfg, :unprotected_hubs)
  end

  test "current/0 is stable — multiple calls return the identical persistent_term" do
    a = ScoringConfig.current()
    b = ScoringConfig.current()
    c = ScoringConfig.current()

    assert a == b
    assert b == c
  end

  test "heatmap_weights/0 contains the four expected component weights summing to ~1.0" do
    weights = ScoringConfig.heatmap_weights()

    assert is_number(weights.centrality)
    assert is_number(weights.complexity)
    assert is_number(weights.test_coverage)
    assert is_number(weights.coupling)

    total = weights.centrality + weights.complexity + weights.test_coverage + weights.coupling
    assert_in_delta total, 1.0, 0.001
  end

  test "heatmap_normalization/0 has all four caps as positive numbers" do
    norm = ScoringConfig.heatmap_normalization()

    for key <- [:centrality_cap, :complexity_cap, :coupling_cap, :missing_test_factor] do
      val = Map.fetch!(norm, key)
      assert is_number(val) and val > 0, "#{key} must be positive, got #{inspect(val)}"
    end
  end

  test "heatmap_zones/0 has red_min > yellow_min" do
    zones = ScoringConfig.heatmap_zones()

    assert zones.red_min > zones.yellow_min
    assert zones.yellow_min > 0
  end

  test "change_risk/0 has weights, centrality_divisor, and top_n" do
    cr = ScoringConfig.change_risk()

    assert is_map(cr.weights)
    assert is_number(cr.centrality_divisor) and cr.centrality_divisor > 0
    assert is_integer(cr.top_n) and cr.top_n > 0
  end

  test "god_modules/0 has weights and top_n" do
    gm = ScoringConfig.god_modules()

    assert is_map(gm.weights)
    assert is_integer(gm.top_n) and gm.top_n > 0
  end

  test "unprotected_hubs/0 has spec_thresholds with red_max < yellow_max" do
    uh = ScoringConfig.unprotected_hubs()

    assert uh.spec_thresholds.red_max < uh.spec_thresholds.yellow_max
    assert is_integer(uh.default_hub_threshold) and uh.default_hub_threshold > 0
  end

  test "reload/0 returns the same map shape as current/0" do
    original = ScoringConfig.current()
    reloaded = ScoringConfig.reload()

    assert Map.keys(original) -- Map.keys(reloaded) == []
    assert Map.keys(reloaded) -- Map.keys(original) == []
  end
end
