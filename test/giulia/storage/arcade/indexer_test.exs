defmodule Giulia.Storage.Arcade.IndexerTest do
  use ExUnit.Case, async: false

  alias Giulia.Storage.Arcade.{Client, Indexer}

  setup_all do
    Client.create_db()
    Client.ensure_schema()
    :ok
  end

  # ============================================================================
  # snapshot/2 — gold path (ArcadeDB is running, graph may be empty)
  # ============================================================================

  describe "snapshot/2" do
    test "succeeds with empty graph for unknown project" do
      {:ok, result} =
        Indexer.snapshot("/test/indexer_empty_#{System.unique_integer([:positive])}", 138)

      assert result.modules.ok == 0
      assert result.functions.ok == 0
      assert result.function_call_edges.ok == 0
      assert result.module_edges.ok == 0
    end

    test "returns ok tuple with module/function/edge counts" do
      {:ok, result} = Indexer.snapshot("/test/indexer_shape", 138)
      assert is_map(result.modules)
      assert is_map(result.functions)
      assert is_map(result.function_call_edges)
      assert is_map(result.module_edges)
      assert Map.has_key?(result.modules, :ok)
      assert Map.has_key?(result.modules, :error)
    end
  end

  # ============================================================================
  # snapshot/2 — adversarial
  # ============================================================================

  describe "snapshot/2 adversarial" do
    test "handles zero build_id without crashing" do
      assert {:ok, _} = Indexer.snapshot("/test/indexer_zero", 0)
    end

    test "handles negative build_id without crashing" do
      assert {:ok, _} = Indexer.snapshot("/test/indexer_neg", -1)
    end

    test "handles very large build_id without crashing" do
      assert {:ok, _} = Indexer.snapshot("/test/indexer_large", 999_999_999)
    end

    test "handles empty project path without crashing" do
      assert {:ok, _} = Indexer.snapshot("", 1)
    end
  end
end
