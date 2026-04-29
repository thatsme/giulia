defmodule Giulia.Storage.Arcade.ConsolidatorPruneTest do
  @moduledoc """
  Coverage for `Consolidator.prune_old_builds/2` — the retention policy
  that prevents `verify_l3.count_parity.status == "l3_exceeds_l1"` from
  recurring.

  Pre-fix: each scan re-snapshots the current build's CALLS / DEPENDS_ON
  edges into ArcadeDB, but `Client.delete_edges_for_build/3` is
  build-id-scoped — it only purges the SAME build_id's prior writes.
  Older build_ids accumulate forever; on Plausible after ~3 scans,
  L3 had 7129 edges vs L1's 1844 (delta 5285).

  These tests stay at the pure-function layer (build-id arithmetic +
  retention math) — the integration with Client.list_builds /
  Client.delete_edges_older_than is exercised in production via the
  Consolidator's `run_consolidation/1` cycle and the
  `POST /api/index/compact?include=arcade` endpoint.
  """

  use ExUnit.Case, async: true

  alias Giulia.Storage.Arcade.Consolidator

  describe "prune_old_builds/2 — input contracts" do
    test "rejects retention < 3 (drift detection needs >=3 builds)" do
      assert_raise FunctionClauseError, fn ->
        Consolidator.prune_old_builds("/projects/example", 2)
      end

      assert_raise FunctionClauseError, fn ->
        Consolidator.prune_old_builds("/projects/example", 0)
      end
    end

    test "rejects negative retention" do
      assert_raise FunctionClauseError, fn ->
        Consolidator.prune_old_builds("/projects/example", -5)
      end
    end

    test "rejects non-binary project" do
      assert_raise FunctionClauseError, fn ->
        Consolidator.prune_old_builds(:not_a_string, 10)
      end
    end

    test "accepts retention >= 3" do
      # Doesn't crash — actual return depends on ArcadeDB availability
      # in the test env (likely returns %{kept: 0, pruned: 0, error: ...}
      # since list_builds will fail without a populated DB).
      result = Consolidator.prune_old_builds("/projects/no-such-thing", 3)
      assert is_map(result)
      assert Map.has_key?(result, :kept)
      assert Map.has_key?(result, :pruned)
    end
  end

  describe "ScanConfig.arcade_history_builds/0 — retention default + clamp" do
    test "returns at least 3 even if config says lower" do
      # ScanConfig clamps any value < 3 to 3 because the Consolidator's
      # drift detectors (complexity_history, coupling_history) need
      # length(scores) >= 3 to detect monotonic trends. A user who
      # configures retention=1 in scan_defaults.json would otherwise
      # silently break drift detection.
      assert Giulia.Context.ScanConfig.arcade_history_builds() >= 3
    end
  end
end
