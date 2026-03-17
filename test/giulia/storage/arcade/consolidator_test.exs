defmodule Giulia.Storage.Arcade.ConsolidatorTest do
  use ExUnit.Case, async: true

  alias Giulia.Storage.Arcade.Consolidator

  # ============================================================================
  # monotonically_increasing?/1
  # ============================================================================

  describe "monotonically_increasing?/1" do
    test "returns true for strictly increasing sequence" do
      assert Consolidator.monotonically_increasing?([1, 2, 3, 4, 5])
    end

    test "returns true for increasing with gaps" do
      assert Consolidator.monotonically_increasing?([5, 10, 50, 100])
    end

    test "returns false for flat sequence" do
      refute Consolidator.monotonically_increasing?([3, 3, 3])
    end

    test "returns false for decreasing sequence" do
      refute Consolidator.monotonically_increasing?([5, 4, 3])
    end

    test "returns false for mixed direction" do
      refute Consolidator.monotonically_increasing?([1, 3, 2, 4])
    end

    test "returns false for single element" do
      refute Consolidator.monotonically_increasing?([42])
    end

    test "returns false for empty list" do
      refute Consolidator.monotonically_increasing?([])
    end

    test "returns true for two increasing elements" do
      assert Consolidator.monotonically_increasing?([1, 2])
    end

    test "returns false when last element equals previous" do
      refute Consolidator.monotonically_increasing?([1, 2, 3, 3])
    end

    test "handles zero values" do
      assert Consolidator.monotonically_increasing?([0, 1, 2])
    end

    test "handles negative values" do
      assert Consolidator.monotonically_increasing?([-3, -2, -1, 0])
    end
  end

  # ============================================================================
  # classify_complexity_severity/1
  # ============================================================================

  describe "classify_complexity_severity/1" do
    test "returns high for score >= 50" do
      assert Consolidator.classify_complexity_severity(50) == "high"
      assert Consolidator.classify_complexity_severity(100) == "high"
    end

    test "returns medium for score >= 20 and < 50" do
      assert Consolidator.classify_complexity_severity(20) == "medium"
      assert Consolidator.classify_complexity_severity(49) == "medium"
    end

    test "returns low for score < 20" do
      assert Consolidator.classify_complexity_severity(0) == "low"
      assert Consolidator.classify_complexity_severity(19) == "low"
    end
  end

  # ============================================================================
  # classify_coupling_severity/1
  # ============================================================================

  describe "classify_coupling_severity/1" do
    test "returns high for score >= 10" do
      assert Consolidator.classify_coupling_severity(10) == "high"
      assert Consolidator.classify_coupling_severity(25) == "high"
    end

    test "returns medium for score >= 5 and < 10" do
      assert Consolidator.classify_coupling_severity(5) == "medium"
      assert Consolidator.classify_coupling_severity(9) == "medium"
    end

    test "returns low for score < 5" do
      assert Consolidator.classify_coupling_severity(0) == "low"
      assert Consolidator.classify_coupling_severity(4) == "low"
    end
  end

  # ============================================================================
  # classify_hotspot_severity/1
  # ============================================================================

  describe "classify_hotspot_severity/1" do
    test "returns high for score >= 40" do
      assert Consolidator.classify_hotspot_severity(40) == "high"
      assert Consolidator.classify_hotspot_severity(99) == "high"
    end

    test "returns medium for score >= 20 and < 40" do
      assert Consolidator.classify_hotspot_severity(20) == "medium"
      assert Consolidator.classify_hotspot_severity(39) == "medium"
    end

    test "returns low for score < 20" do
      assert Consolidator.classify_hotspot_severity(0) == "low"
      assert Consolidator.classify_hotspot_severity(19) == "low"
    end
  end

  # ============================================================================
  # group_by_module/1
  # ============================================================================

  describe "group_by_module/1" do
    test "groups rows by module name sorted by build_id" do
      rows = [
        %{"name" => "A", "build_id" => 3, "complexity_score" => 30},
        %{"name" => "B", "build_id" => 1, "complexity_score" => 10},
        %{"name" => "A", "build_id" => 1, "complexity_score" => 10},
        %{"name" => "A", "build_id" => 2, "complexity_score" => 20},
        %{"name" => "B", "build_id" => 2, "complexity_score" => 15}
      ]

      result = Consolidator.group_by_module(rows)
      grouped = Map.new(result)

      assert length(grouped["A"]) == 3
      assert length(grouped["B"]) == 2

      # Verify sorted by build_id
      a_builds = Enum.map(grouped["A"], & &1["build_id"])
      assert a_builds == [1, 2, 3]
    end

    test "handles empty list" do
      assert Consolidator.group_by_module([]) == []
    end

    test "handles single row" do
      rows = [%{"name" => "X", "build_id" => 1}]
      [{name, builds}] = Consolidator.group_by_module(rows)
      assert name == "X"
      assert length(builds) == 1
    end

    test "handles nil name gracefully" do
      rows = [%{"name" => nil, "build_id" => 1}]
      [{name, _}] = Consolidator.group_by_module(rows)
      assert name == nil
    end
  end

  # ============================================================================
  # detect_complexity_drift/2 — adversarial
  # ============================================================================

  describe "detect_complexity_drift/2 adversarial" do
    test "returns empty list when ArcadeDB is unavailable" do
      # ArcadeDB not running in test — Client.complexity_history will fail
      assert Consolidator.detect_complexity_drift("/fake/project", 138) == []
    end
  end

  # ============================================================================
  # detect_coupling_drift/2 — adversarial
  # ============================================================================

  describe "detect_coupling_drift/2 adversarial" do
    test "returns empty list when ArcadeDB is unavailable" do
      assert Consolidator.detect_coupling_drift("/fake/project", 138) == []
    end
  end

  # ============================================================================
  # detect_hotspots/2 — adversarial
  # ============================================================================

  describe "detect_hotspots/2 adversarial" do
    test "returns empty list when ArcadeDB is unavailable" do
      assert Consolidator.detect_hotspots("/fake/project", 138) == []
    end
  end

  # ============================================================================
  # status/0
  # ============================================================================

  describe "status/0" do
    test "returns initial state" do
      state = Consolidator.status()
      assert is_map(state)
      assert state.run_count >= 0
      assert Map.has_key?(state, :last_run)
      assert Map.has_key?(state, :last_result)
      assert Map.has_key?(state, :interval)
    end
  end
end
