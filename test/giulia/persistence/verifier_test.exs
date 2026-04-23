defmodule Giulia.Persistence.VerifierTest do
  @moduledoc """
  CI guard for the L1↔L2 round-trip verifier.

  `Persistence.Verifier` is the enforcement surface of correctness-
  floor Step 1: a failing verifier run is a shipping-blocker because
  it proves cross-store sync between L1 (ETS) and L2 (CubDB) has
  silently drifted.

  Without these tests the verifier only ran against the live daemon
  via `GET /api/knowledge/verify_l2`, so regressions were invisible
  to PRs. These tests populate L1 + L2 deterministically and assert
  both:

    * **Happy path** — faithful L1→L2 round-trip must report
      `overall: :pass`. If it doesn't, either the verifier or the
      write path is broken.
    * **Drift detection** — deliberately corrupted L2 state must
      report `overall: :fail`. If it doesn't, the verifier is
      vacuously green — reporting pass no matter what.

  L2 is written synchronously here rather than through the debounced
  `Persistence.Writer` to keep the test deterministic. The verifier
  reads from L2 regardless of how it got there, so direct writes are
  equivalent for our purposes.
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Store, as: ContextStore
  alias Giulia.Knowledge.Store, as: KnowledgeStore
  alias Giulia.Persistence.{Store, Verifier}

  @knowledge_table :giulia_knowledge_graphs

  setup do
    ensure_started!(ContextStore)
    ensure_started!(KnowledgeStore)
    ensure_started!(Store)

    project = "/test/verifier_l2_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ContextStore.clear_asts(project)
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

  # Three-module fixture: Alpha depends on Beta, Gamma depends on Beta.
  # Mirrors the setup in Knowledge.StoreTest so behavior converges.
  defp populate_l1!(project) do
    ContextStore.put_ast(project, "lib/alpha.ex", %{
      modules: [%{name: "Alpha", line: 1}],
      functions: [
        %{name: :run, arity: 1, type: :def, line: 3},
        %{name: :stop, arity: 0, type: :def, line: 10}
      ],
      imports: [%{module: "Beta", type: :alias, line: 2}],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    ContextStore.put_ast(project, "lib/beta.ex", %{
      modules: [%{name: "Beta", line: 1}],
      functions: [%{name: :process, arity: 2, type: :def, line: 3}],
      imports: [],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    ContextStore.put_ast(project, "lib/gamma.ex", %{
      modules: [%{name: "Gamma", line: 1}],
      functions: [%{name: :transform, arity: 1, type: :def, line: 3}],
      imports: [%{module: "Beta", type: :alias, line: 2}],
      structs: [],
      callbacks: [],
      types: [],
      specs: [],
      docs: []
    })

    ast_data = ContextStore.all_asts(project)
    :ok = KnowledgeStore.rebuild(project, ast_data)
    ast_data
  end

  defp persist_graph_to_l2!(project) do
    [{_, graph}] = :ets.lookup(@knowledge_table, {:graph, project})
    {:ok, db} = Store.get_db(project)
    CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(graph, [:compressed]))
    :ok
  end

  defp persist_ast_to_l2!(project, ast_data) do
    {:ok, db} = Store.get_db(project)

    entries = Enum.map(ast_data, fn {file, data} -> {{:ast, file}, data} end)
    CubDB.put_multi(db, entries)
    :ok
  end

  defp persist_metrics_to_l2!(project, metrics) do
    :ets.insert(@knowledge_table, {{:metrics, project}, metrics})
    {:ok, db} = Store.get_db(project)
    CubDB.put(db, {:metrics, :cached}, metrics)
    :ok
  end

  # ============================================================================
  # verify_graph/2
  # ============================================================================

  describe "verify_graph/2 — happy path" do
    test "faithful L1→L2 round-trip passes", %{project: project} do
      populate_l1!(project)
      persist_graph_to_l2!(project)

      {:ok, report} = Verifier.verify_graph(project)

      assert report.overall == :pass,
             "faithful round-trip should pass but got: #{inspect(report)}"

      assert report.l1_present
      assert report.l2_present
      assert report.vertex_parity.status == :match
      assert report.edge_parity.status == :match
      assert report.sample_identity.overall == :pass
    end

    test "reports absence when only L1 is populated", %{project: project} do
      populate_l1!(project)
      # Skip persist_graph_to_l2! — L2 remains empty.

      {:ok, report} = Verifier.verify_graph(project)
      assert report.overall == :incomplete
      assert report.l1_present
      refute report.l2_present
    end
  end

  describe "verify_graph/2 — drift detection" do
    test "detects missing L2 edge (count parity fails)", %{project: project} do
      populate_l1!(project)

      # Persist a tampered graph: drop one edge.
      [{_, graph}] = :ets.lookup(@knowledge_table, {:graph, project})
      [edge | _rest] = Graph.edges(graph)
      tampered = Graph.delete_edge(graph, edge.v1, edge.v2)

      {:ok, db} = Store.get_db(project)
      CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(tampered, [:compressed]))

      {:ok, report} = Verifier.verify_graph(project)
      assert report.overall == :fail,
             "dropping an edge from L2 must be caught — report was: #{inspect(report)}"

      assert report.edge_parity.status == :mismatch
    end

    test "detects extra L2 vertex (vertex parity fails)", %{project: project} do
      populate_l1!(project)

      [{_, graph}] = :ets.lookup(@knowledge_table, {:graph, project})
      # Inject a vertex into L2 that L1 doesn't have.
      tampered = Graph.add_vertex(graph, "Phantom", :module)

      {:ok, db} = Store.get_db(project)
      CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(tampered, [:compressed]))

      {:ok, report} = Verifier.verify_graph(project)
      assert report.overall == :fail
      assert report.vertex_parity.status == :mismatch
      assert report.vertex_parity.extra_in_l2 >= 1
    end
  end

  # ============================================================================
  # verify_ast/2
  # ============================================================================

  describe "verify_ast/2 — happy path" do
    test "faithful AST round-trip passes", %{project: project} do
      ast_data = populate_l1!(project)
      persist_ast_to_l2!(project, ast_data)

      {:ok, report} = Verifier.verify_ast(project)

      assert report.overall == :pass,
             "faithful AST round-trip should pass but got: #{inspect(report)}"

      assert report.file_set_parity.status == :match
      assert report.sample_identity.mismatched == 0
    end
  end

  describe "verify_ast/2 — drift detection" do
    test "detects file missing in L2", %{project: project} do
      ast_data = populate_l1!(project)
      # Drop one file from what we persist to L2.
      truncated = Map.drop(ast_data, [List.first(Map.keys(ast_data))])
      persist_ast_to_l2!(project, truncated)

      {:ok, report} = Verifier.verify_ast(project)
      assert report.overall == :fail
      assert report.file_set_parity.status == :mismatch
      assert report.file_set_parity.missing_in_l2 >= 1
    end

    test "detects content drift for a file present in both", %{project: project} do
      ast_data = populate_l1!(project)

      # Persist tampered data for one file — keep filename, change content.
      [{file, _original} | _rest] = Map.to_list(ast_data)
      tampered = Map.put(ast_data, file, %{modules: [%{name: "Different", line: 1}]})
      persist_ast_to_l2!(project, tampered)

      {:ok, report} = Verifier.verify_ast(project)
      # file_set still matches (same keys) — but sample identity fails.
      assert report.overall == :fail
      assert report.sample_identity.mismatched >= 1
    end
  end

  # ============================================================================
  # verify_metrics/1
  # ============================================================================

  describe "verify_metrics/1 — happy path" do
    test "faithful metrics round-trip passes", %{project: project} do
      metrics = %{
        heatmap: %{"Alpha" => 0.5, "Beta" => 0.9},
        change_risk: %{"Alpha" => :low, "Beta" => :high},
        coupling: %{}
      }

      persist_metrics_to_l2!(project, metrics)

      {:ok, report} = Verifier.verify_metrics(project)
      assert report.overall == :pass
      assert report.mismatched_keys == []
      assert report.l2_only == []
    end

    test "empty L1 + empty L2 is :pass (both sides absent)", %{project: project} do
      {:ok, report} = Verifier.verify_metrics(project)
      assert report.overall == :pass
      assert report.l1_keys == 0
      assert report.l2_keys == 0
    end
  end

  describe "verify_metrics/1 — drift detection" do
    test "detects value mismatch for a shared key", %{project: project} do
      l1_metrics = %{heatmap: %{"Alpha" => 0.5}}
      l2_metrics = %{heatmap: %{"Alpha" => 0.9}}

      :ets.insert(@knowledge_table, {{:metrics, project}, l1_metrics})
      {:ok, db} = Store.get_db(project)
      CubDB.put(db, {:metrics, :cached}, l2_metrics)

      {:ok, report} = Verifier.verify_metrics(project)
      assert report.overall == :fail
      assert :heatmap in report.mismatched_keys
    end

    test "detects key present in L2 but not L1 (L2 drift)", %{project: project} do
      :ets.insert(@knowledge_table, {{:metrics, project}, %{heatmap: %{}}})
      {:ok, db} = Store.get_db(project)
      CubDB.put(db, {:metrics, :cached}, %{heatmap: %{}, stale_key: :leftover})

      {:ok, report} = Verifier.verify_metrics(project)
      assert report.overall == :fail
      assert :stale_key in report.l2_only
    end
  end
end
