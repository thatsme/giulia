defmodule Giulia.Knowledge.StoreInvalidationTest do
  @moduledoc """
  Tests for `Store.invalidate_enrichment_dependent_caches/1`.

  Protects the scoped-invalidation invariant: an enrichment ingest must drop
  the cached `:dead_code` result (the only cached analysis that embeds
  enrichment findings) while leaving the heavy graph metrics cached. Clearing
  the whole metrics map would force a full recompute on every ingest; clearing
  nothing leaves stale `%{}` enrichments (the Bug #3 collaudo failure).

  Seeds the shared knowledge ETS cache directly under a unique project key so
  it cannot collide with a real project's cache.
  """
  use ExUnit.Case, async: false

  alias Giulia.Knowledge.Store

  @table :giulia_knowledge_graphs

  setup do
    pp = "/test/store_invalidation_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(@table, {:metrics, pp}) end)
    %{pp: pp}
  end

  defp seed(pp, metrics), do: :ets.insert(@table, {{:metrics, pp}, metrics})
  defp read(pp), do: :ets.lookup(@table, {:metrics, pp})

  describe "invalidate_enrichment_dependent_caches/1" do
    test "drops :dead_code but keeps the heavy graph metrics", %{pp: pp} do
      seed(pp, %{
        dead_code: %{dead: [:stale]},
        heatmap: %{a: 1},
        change_risk: %{b: 2},
        god_modules: %{c: 3},
        coupling: %{d: 4}
      })

      assert Store.invalidate_enrichment_dependent_caches(pp) == :cleared

      [{_, m}] = read(pp)
      refute Map.has_key?(m, :dead_code)
      assert Map.has_key?(m, :heatmap)
      assert Map.has_key?(m, :change_risk)
      assert Map.has_key?(m, :god_modules)
      assert Map.has_key?(m, :coupling)
    end

    test "returns :absent when the metrics map has no :dead_code entry", %{pp: pp} do
      seed(pp, %{heatmap: %{a: 1}})

      assert Store.invalidate_enrichment_dependent_caches(pp) == :absent
      # The untouched metric must survive — invalidation is not a sweep.
      [{_, m}] = read(pp)
      assert Map.has_key?(m, :heatmap)
    end

    test "returns :absent when the project has no cached metrics at all", %{pp: pp} do
      assert read(pp) == []
      assert Store.invalidate_enrichment_dependent_caches(pp) == :absent
    end
  end
end
