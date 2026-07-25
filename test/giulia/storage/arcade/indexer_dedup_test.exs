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

  ## Everything here is scoped to the project under test

  `Indexer` state is global and other tests trigger snapshots for their own
  projects, so `map_size(in_flight)` and "wait until in_flight is empty" are
  both meaningless as assertions — the first counts unrelated projects, the
  second may never be true while the suite runs. The first version of this file
  did both and failed intermittently, reporting `in_flight_count() == 2` (two
  different projects, working correctly) and a settle timeout of
  `{:timeout, 1, 0}` (someone else's snapshot).

  Note also that "at most one in flight per project" needs no assertion:
  `in_flight` is a map keyed by project, so it holds structurally. What is worth
  testing is the behaviour around it — coalescing keeps the newest build, slots
  are always released, and unrelated projects are not serialised.
  """
  use ExUnit.Case, async: false

  alias Giulia.Storage.Arcade.Indexer

  @knowledge_table :giulia_knowledge_graphs

  setup do
    project = "/test/dedup_#{System.unique_integer([:positive])}"

    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("Dedup.Alpha", :module)
      |> Graph.add_vertex("Dedup.Beta", :module)
      |> Graph.add_edge("Dedup.Alpha", "Dedup.Beta", label: :depends_on)

    :ets.insert(@knowledge_table, {{:graph, project}, graph})
    on_exit(fn -> :ets.delete(@knowledge_table, {:graph, project}) end)

    %{project: project}
  end

  defp state, do: :sys.get_state(Indexer)

  defp busy?(project) do
    s = state()
    Map.has_key?(s.in_flight, project) or Map.has_key?(s.pending, project)
  end

  # Wait for THIS project to drain. Other projects may be mid-snapshot
  # throughout and that is correct.
  defp settle(project, timeout_ms \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_settle(project, deadline)
  end

  defp do_settle(project, deadline) do
    cond do
      not busy?(project) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:timeout, Map.get(state().in_flight, project), Map.get(state().pending, project)}

      true ->
        Process.sleep(25)
        do_settle(project, deadline)
    end
  end

  test "a burst of graph_ready leaves no leaked slot", %{project: project} do
    # Ten rebuilds in a burst — the shape a fast edit-scan loop produces. The
    # gate must absorb them and end clean: a leaked in_flight entry would lock
    # this project out of every future snapshot, silently and permanently.
    for build <- 1..10, do: send(Indexer, {:graph_ready, project, build})

    assert settle(project) == :ok
    refute Map.has_key?(state().in_flight, project)
    refute Map.has_key?(state().pending, project)
  end

  test "coalescing keeps the newest build", %{project: project} do
    send(Indexer, {:graph_ready, project, 1})
    send(Indexer, {:graph_ready, project, 2})
    send(Indexer, {:graph_ready, project, 3})

    # Whatever is queued must be the LATEST build — keeping an older one would
    # leave L3 behind L1, the drift this exists to prevent. If the first
    # snapshot already finished, nothing is queued and there is nothing to
    # check; the assertion is conditional on observing the state, never on
    # winning a race.
    case Map.get(state().pending, project) do
      nil -> :ok
      queued -> assert queued == 3, "coalescing must keep the newest build, kept #{queued}"
    end

    assert settle(project) == :ok
  end

  test "distinct projects are not serialised against each other", %{project: project} do
    other = "/test/dedup_other_#{System.unique_integer([:positive])}"
    :ets.insert(@knowledge_table, {{:graph, other}, Graph.new(type: :directed)})
    on_exit(fn -> :ets.delete(@knowledge_table, {:graph, other}) end)

    send(Indexer, {:graph_ready, project, 1})
    send(Indexer, {:graph_ready, other, 1})

    # Both drain independently. Serialising unrelated projects would turn a
    # correctness fix into a throughput regression.
    assert settle(project) == :ok
    assert settle(other) == :ok
  end

  test "the slot is released even when the snapshot has nothing to write" do
    orphan = "/test/dedup_orphan_#{System.unique_integer([:positive])}"

    send(Indexer, {:graph_ready, orphan, 1})

    assert settle(orphan) == :ok
    refute Map.has_key?(state().in_flight, orphan)
  end
end
