defmodule Giulia.Persistence.WarmRestoreTest do
  @moduledoc """
  Verifies `WarmRestore.run_for/1` repopulates L1 from L2 for a
  synthetic project whose L2 state was seeded directly.

  The goal is to prove the round-trip: a graph persisted to CubDB
  (L2) is visible in `Knowledge.Store.list_projects/0` (L1) after
  `run_for/1`, which is what `GET /api/projects` depends on and
  what was empty after `docker compose restart` before this module
  existed.

  Discovery (`WarmRestore.discover_projects/0`) walks the filesystem
  for `.giulia/cache/cubdb*` directories and is exercised separately
  — it's environment-dependent and not what the regression is about.
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Store, as: ContextStore
  alias Giulia.Knowledge.Store, as: KnowledgeStore
  alias Giulia.Persistence.{Store, WarmRestore}

  @knowledge_table :giulia_knowledge_graphs

  setup do
    ensure_started!(ContextStore)
    ensure_started!(KnowledgeStore)
    ensure_started!(Store)

    project = "/test/warm_restore_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :ets.delete(@knowledge_table, {:graph, project})
      :ets.delete(@knowledge_table, {:metrics, project})
      Store.close(project)
    end)

    %{project: project}
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!({module, []})
      _pid -> :ok
    end
  end

  defp seed_l2!(project) do
    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("Alpha", :module)
      |> Graph.add_vertex("Beta", :module)
      |> Graph.add_edge("Alpha", "Beta", label: :depends_on)

    {:ok, db} = Store.get_db(project)
    CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(graph, [:compressed]))
    graph
  end

  describe "run_for/1" do
    test "repopulates L1 from L2 for a persisted project", %{project: project} do
      seed_l2!(project)

      # Precondition: L1 is empty for this project.
      refute project in KnowledgeStore.list_projects()

      restored = WarmRestore.run_for([project])

      assert restored == [project]
      assert project in KnowledgeStore.list_projects(),
             "restored project must appear in Knowledge.Store.list_projects/0 — " <>
               "that's what /api/projects reads and what was empty after restart"

      [{_, graph}] = :ets.lookup(@knowledge_table, {:graph, project})
      assert "Alpha" in Graph.vertices(graph)
      assert "Beta" in Graph.vertices(graph)
    end

    test "returns empty list for projects with no L2 state", %{project: project} do
      # No seed — L2 is empty for this project.
      assert WarmRestore.run_for([project]) == []
      refute project in KnowledgeStore.list_projects()
    end

    test "partial restore across a mixed batch", %{project: project} do
      seeded = project
      unseeded = "/test/warm_restore_unseeded_#{System.unique_integer([:positive])}"

      seed_l2!(seeded)

      restored = WarmRestore.run_for([seeded, unseeded])

      assert restored == [seeded]
      assert seeded in KnowledgeStore.list_projects()
      refute unseeded in KnowledgeStore.list_projects()

      on_exit(fn ->
        :ets.delete(@knowledge_table, {:graph, unseeded})
        :ets.delete(@knowledge_table, {:metrics, unseeded})
        Store.close(unseeded)
      end)
    end
  end

  describe "discover_projects/0" do
    test "returns a list (environment-dependent content)" do
      # Shape check only — actual content depends on the filesystem.
      # In-container tests may find persisted projects under /projects;
      # dev-machine tests may find none. Either is valid.
      result = WarmRestore.discover_projects()
      assert is_list(result)
      assert Enum.all?(result, &is_binary/1)
    end
  end
end
