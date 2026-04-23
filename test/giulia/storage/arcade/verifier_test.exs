defmodule Giulia.Storage.Arcade.VerifierTest do
  @moduledoc """
  CI guard for the L1→L3 round-trip verifier.

  `Arcade.Verifier.verify/2` is the enforcement surface for L3 (ArcadeDB
  CALLS edges). A failing run proves function-level :calls edges are
  out of sync between L1 (libgraph) and L3 (ArcadeDB). These tests
  populate L1 deterministically, snapshot to L3 via the real Indexer,
  and assert both:

    * **Happy path** — faithful round-trip must report `overall: :pass`
      with `count_parity.status == :match`.
    * **Drift detection** — L1 diverging from L3 (edge added to L1 but
      not re-snapshotted) must report `overall: :fail` with
      `count_parity.status == :l3_under_l1`.

  The L1 graph is constructed directly with libgraph and inserted into
  the ETS table, bypassing the Builder's AST-extraction pipeline. This
  keeps the test hermetic — we care that the verifier catches drift
  given known L1 state, not whether the Builder correctly extracts
  calls from synthetic ASTs.

  Requires the `arcadedb` container to be running (same precondition as
  `Giulia.Storage.Arcade.IndexerTest`).
  """
  use ExUnit.Case, async: false

  alias Giulia.Storage.Arcade.{Client, Indexer, Verifier}

  @knowledge_table :giulia_knowledge_graphs

  setup_all do
    Client.create_db()
    Client.ensure_schema()
    :ok
  end

  setup do
    ensure_started!(Giulia.Context.Store)
    ensure_started!(Giulia.Knowledge.Store)

    project = "/test/verifier_l3_#{System.unique_integer([:positive])}"
    build_id = System.unique_integer([:positive])

    on_exit(fn ->
      # Purge L3 edges for this (project, build_id) so test-created
      # snapshots don't accumulate in ArcadeDB across runs.
      Client.delete_edges_for_build("CALLS", project, build_id)
      Client.delete_edges_for_build("DEPENDS_ON", project, build_id)
      :ets.delete(@knowledge_table, {:graph, project})
    end)

    %{project: project, build_id: build_id}
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!({module, []})
      _pid -> :ok
    end
  end

  # Build a minimal L1 graph with 3 function vertices and 2 :calls
  # edges across different `:via` buckets so the verifier's stratified
  # sample touches more than one stratum.
  defp insert_l1_graph!(project) do
    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("Alpha", :module)
      |> Graph.add_vertex("Beta", :module)
      |> Graph.add_vertex("Gamma", :module)
      |> Graph.add_vertex("Alpha.run/1", :function)
      |> Graph.add_vertex("Beta.process/2", :function)
      |> Graph.add_vertex("Gamma.transform/1", :function)
      |> Graph.add_edge("Alpha", "Beta", label: :depends_on)
      |> Graph.add_edge("Gamma", "Beta", label: :depends_on)
      |> Graph.add_edge("Alpha.run/1", "Beta.process/2", label: {:calls, :direct})
      |> Graph.add_edge("Gamma.transform/1", "Beta.process/2", label: {:calls, :alias_resolved})

    :ets.insert(@knowledge_table, {{:graph, project}, graph})
    graph
  end

  defp add_l1_edge!(project, from, to, via) do
    [{_, graph}] = :ets.lookup(@knowledge_table, {:graph, project})
    updated = Graph.add_edge(graph, from, to, label: {:calls, via})
    :ets.insert(@knowledge_table, {{:graph, project}, updated})
    updated
  end

  # ============================================================================
  # verify/2 — happy path
  # ============================================================================

  describe "verify/2 — happy path" do
    test "faithful L1→L3 snapshot round-trips clean", %{project: project, build_id: build_id} do
      insert_l1_graph!(project)

      {:ok, _snapshot} = Indexer.snapshot(project, build_id)

      {:ok, report} = Verifier.verify(project, sample_per_bucket: 10)

      assert report.overall == :pass,
             "faithful L1→L3 round-trip should pass but got: #{inspect(report)}"

      assert report.count_parity.status == :match,
             "count parity should match — L1=#{report.l1_calls_total} L3=#{report.l3_calls_total}"

      assert report.l1_calls_total == 2
      assert report.l3_calls_total == 2
    end

    test "empty L1 snapshot produces :match with zero counts",
         %{project: project, build_id: build_id} do
      # Insert a graph with no :calls edges at all.
      empty_graph = Graph.new(type: :directed)
      :ets.insert(@knowledge_table, {{:graph, project}, empty_graph})

      {:ok, _} = Indexer.snapshot(project, build_id)

      {:ok, report} = Verifier.verify(project)
      assert report.overall == :pass
      assert report.l1_calls_total == 0
      assert report.l3_calls_total == 0
      assert report.count_parity.status == :match
    end
  end

  # ============================================================================
  # verify/2 — drift detection
  # ============================================================================

  describe "verify/2 — drift detection" do
    test "detects L1 edges added post-snapshot (l3_under_l1)",
         %{project: project, build_id: build_id} do
      insert_l1_graph!(project)
      {:ok, _} = Indexer.snapshot(project, build_id)

      # Add another :calls edge to L1 — simulating a pass that ran
      # after the last snapshot. L3 is now stale.
      add_l1_edge!(project, "Alpha.run/1", "Gamma.transform/1", :direct)

      {:ok, report} = Verifier.verify(project)
      assert report.overall == :fail,
             "adding an L1 edge without re-snapshotting must be caught"

      assert report.count_parity.status == :l3_under_l1
      assert report.count_parity.l1 == 3
      assert report.count_parity.l3 == 2
      assert report.count_parity.delta == 1
    end

    test "detects L3 edges accumulated beyond L1 (l3_exceeds_l1)",
         %{project: project, build_id: build_id} do
      insert_l1_graph!(project)
      {:ok, _} = Indexer.snapshot(project, build_id)

      # Inject an extra CALLS edge directly into L3 — simulating a
      # non-idempotent re-insert or a stale record from a previous run
      # that didn't get purged.
      {:ok, _} =
        Client.insert_call(
          project,
          "Alpha.run/1",
          "Gamma.transform/1",
          build_id
        )

      {:ok, report} = Verifier.verify(project)
      assert report.overall == :fail
      assert report.count_parity.status == :l3_exceeds_l1
      assert report.count_parity.delta == 1
    end
  end
end
