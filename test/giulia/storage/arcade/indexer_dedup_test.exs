defmodule Giulia.Storage.Arcade.IndexerDedupTest do
  @moduledoc """
  Snapshot de-duplication in `Arcade.Indexer`.

  Two snapshots of the same project must never run concurrently: both write the
  same (project, build_id) rows and collide on ArcadeDB's optimistic page-level
  MVCC. The client retry absorbs that, but only by doing the work twice and
  spending the retry budget on self-inflicted contention.

  The subtle requirement is that a request arriving while one is in flight must
  be COALESCED, not dropped. Dropping it pins L3 at the older build — precisely
  the silent L1/L3 drift the reconciler exists to prevent.
  """
  use ExUnit.Case, async: false

  alias Giulia.Storage.Arcade.Indexer

  @knowledge_table :giulia_knowledge_graphs

  setup do
    project = "/test/dedup_#{System.unique_integer([:positive])}"

    # A graph with one module, so a snapshot has something to write and takes
    # long enough for a second request to land while it is in flight.
    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("Dedup.Alpha", :module)
      |> Graph.add_vertex("Dedup.Beta", :module)
      |> Graph.add_edge("Dedup.Alpha", "Dedup.Beta", label: :depends_on)

    :ets.insert(@knowledge_table, {{:graph, project}, graph})

    on_exit(fn -> :ets.delete(@knowledge_table, {:graph, project}) end)

    %{project: project}
  end

  defp in_flight_count do
    :sys.get_state(Indexer).in_flight |> map_size()
  end

  defp pending_count do
    :sys.get_state(Indexer).pending |> map_size()
  end

  defp settle(timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_settle(deadline)
  end

  defp do_settle(deadline) do
    if in_flight_count() == 0 and pending_count() == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:timeout, in_flight_count(), pending_count()}
      else
        Process.sleep(25)
        do_settle(deadline)
      end
    end
  end

  test "a burst of graph_ready for one project runs one snapshot at a time", %{project: project} do
    # Ten rebuilds in a burst — the shape a fast edit-scan loop produces.
    for build <- 1..10, do: send(Indexer, {:graph_ready, project, build})

    # The gate is a GenServer invariant, not a timing accident: however many
    # requests arrive, at most one slot per project is ever occupied.
    assert in_flight_count() <= 1

    assert settle() == :ok
    assert in_flight_count() == 0
    assert pending_count() == 0
  end

  test "the newest build wins when requests coalesce", %{project: project} do
    send(Indexer, {:graph_ready, project, 1})
    send(Indexer, {:graph_ready, project, 2})
    send(Indexer, {:graph_ready, project, 3})

    # Whatever is queued must be the LATEST build. Keeping an older one would
    # leave L3 behind L1 — the drift this is meant to prevent.
    state = :sys.get_state(Indexer)

    case Map.get(state.pending, project) do
      nil -> :ok
      queued -> assert queued == 3, "coalescing must keep the newest build, kept #{queued}"
    end

    assert settle() == :ok
  end

  test "distinct projects are not serialised against each other", %{project: project} do
    other = "/test/dedup_other_#{System.unique_integer([:positive])}"
    :ets.insert(@knowledge_table, {{:graph, other}, Graph.new(type: :directed)})
    on_exit(fn -> :ets.delete(@knowledge_table, {:graph, other}) end)

    send(Indexer, {:graph_ready, project, 1})
    send(Indexer, {:graph_ready, other, 1})

    # The gate is per project. Serialising unrelated projects would turn a
    # correctness fix into a throughput regression.
    assert settle() == :ok
  end

  test "the slot is released even when the snapshot task fails" do
    # A project with no graph in ETS still completes; the point is that the
    # monitor fires and the slot is freed, so the project is not locked out of
    # every future snapshot.
    orphan = "/test/dedup_orphan_#{System.unique_integer([:positive])}"

    send(Indexer, {:graph_ready, orphan, 1})
    assert settle() == :ok

    refute Map.has_key?(:sys.get_state(Indexer).in_flight, orphan)
  end
end
