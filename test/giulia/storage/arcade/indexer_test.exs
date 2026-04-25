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

  describe "reconcile_now/0 — closes the silent-loss gap" do
    test "snapshots a project whose current build is missing from ArcadeDB" do
      # Inject a graph with one module vertex so the snapshot actually
      # writes a row to ArcadeDB (an empty graph would write zero modules
      # and Client.list_builds would never return our build_id, defeating
      # the second-pass idempotency check).
      project = "/test/reconcile_#{System.unique_integer([:positive])}"

      graph =
        Graph.new(type: :directed)
        |> Graph.add_vertex("Reconcile.TestModule", [:module])

      :ets.insert(:giulia_knowledge_graphs, {{:graph, project}, graph})

      on_exit(fn ->
        :ets.delete(:giulia_knowledge_graphs, {{:graph, project}})
      end)

      # Pre-condition: ArcadeDB has no record of this project for any build.
      current_build = Giulia.Version.build()
      {:ok, builds_before} = Client.list_builds(project)
      refute Enum.any?(builds_before, &(&1["build_id"] == current_build))

      reconciled = Indexer.reconcile_now()

      assert {^project, ^current_build} =
               Enum.find(reconciled, fn {p, _} -> p == project end)

      # Second pass is a no-op because the snapshot is now present.
      assert Indexer.reconcile_now()
             |> Enum.find(fn {p, _} -> p == project end) == nil
    end
  end
end
