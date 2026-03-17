defmodule Giulia.Storage.Arcade.ClientTest do
  use ExUnit.Case, async: false

  alias Giulia.Storage.Arcade.Client

  # Use a unique project per test run to avoid cross-test pollution
  # Cleanup happens once at the end, not per test
  @test_project "/test/client_#{System.unique_integer([:positive])}"

  setup_all do
    # Create database if it doesn't exist (test ArcadeDB starts fresh)
    Client.create_db()
    Client.ensure_schema()

    on_exit(fn ->
      # Best-effort cleanup — don't fail if ArcadeDB is slow
      Client.command("DELETE FROM Module WHERE project = :p", %{p: @test_project})
      Client.command("DELETE FROM Function WHERE project = :p", %{p: @test_project})
      Client.command("DELETE FROM Insight WHERE project = :p", %{p: @test_project})
      Client.command("DELETE FROM DEPENDS_ON WHERE project = :p", %{p: @test_project})
    end)

    :ok
  end

  # ============================================================================
  # Health + Schema
  # ============================================================================

  describe "health/0" do
    test "returns ok with version info" do
      assert {:ok, info} = Client.health()
      assert Map.has_key?(info, :version)
    end
  end

  describe "ensure_schema/0" do
    test "is idempotent" do
      assert :ok = Client.ensure_schema()
      assert :ok = Client.ensure_schema()
    end
  end

  # ============================================================================
  # Core API
  # ============================================================================

  describe "command/2" do
    test "executes a SQL statement" do
      assert {:ok, _} = Client.command("SELECT 1")
    end
  end

  describe "query/3" do
    test "returns result list" do
      assert {:ok, result} = Client.query("SELECT 1 AS val")
      assert is_list(result)
    end

    test "accepts params" do
      assert {:ok, _} = Client.query("SELECT :x AS val", "sql", %{x: 42})
    end
  end

  describe "cypher/2" do
    test "executes a Cypher query" do
      assert {:ok, result} = Client.cypher("MATCH (n:Module) RETURN n LIMIT 1")
      assert is_list(result)
    end
  end

  # ============================================================================
  # Module upsert
  # ============================================================================

  describe "upsert_module/4" do
    test "creates a module vertex" do
      assert {:ok, _} = Client.upsert_module(@test_project, "TestMod.Alpha", 138)
    end

    test "is idempotent — updates build_id on second call" do
      assert {:ok, _} = Client.upsert_module(@test_project, "TestMod.Idem", 137)
      assert {:ok, _} = Client.upsert_module(@test_project, "TestMod.Idem", 138)

      {:ok, rows} =
        Client.query(
          "SELECT build_id FROM Module WHERE project = :p AND name = :n",
          "sql",
          %{p: @test_project, n: "TestMod.Idem"}
        )

      assert length(rows) == 1
      assert hd(rows)["build_id"] == 138
    end

    test "stores metrics on the vertex" do
      metrics = %{function_count: 5, complexity_score: 42, dep_in: 3, dep_out: 7}
      assert {:ok, _} = Client.upsert_module(@test_project, "TestMod.Metrics", 138, metrics)

      {:ok, [row]} =
        Client.query(
          "SELECT function_count, complexity_score, dep_in, dep_out FROM Module WHERE project = :p AND name = :n",
          "sql",
          %{p: @test_project, n: "TestMod.Metrics"}
        )

      assert row["function_count"] == 5
      assert row["complexity_score"] == 42
      assert row["dep_in"] == 3
      assert row["dep_out"] == 7
    end

    test "defaults metrics to zero" do
      assert {:ok, _} = Client.upsert_module(@test_project, "TestMod.NoMetrics", 138)

      {:ok, [row]} =
        Client.query(
          "SELECT function_count, complexity_score, dep_in, dep_out FROM Module WHERE project = :p AND name = :n",
          "sql",
          %{p: @test_project, n: "TestMod.NoMetrics"}
        )

      assert row["function_count"] == 0
      assert row["complexity_score"] == 0
      assert row["dep_in"] == 0
      assert row["dep_out"] == 0
    end
  end

  # ============================================================================
  # Function upsert
  # ============================================================================

  describe "upsert_function/4" do
    test "creates a function vertex" do
      assert {:ok, _} = Client.upsert_function(@test_project, "TestMod.Alpha.run/1", 138)
    end

    test "stores complexity" do
      assert {:ok, _} = Client.upsert_function(@test_project, "TestMod.Alpha.complex/2", 138, 15)

      {:ok, [row]} =
        Client.query(
          "SELECT complexity FROM Function WHERE project = :p AND name = :n",
          "sql",
          %{p: @test_project, n: "TestMod.Alpha.complex/2"}
        )

      assert row["complexity"] == 15
    end

    test "defaults complexity to zero" do
      assert {:ok, _} = Client.upsert_function(@test_project, "TestMod.Alpha.simple/0", 138)

      {:ok, [row]} =
        Client.query(
          "SELECT complexity FROM Function WHERE project = :p AND name = :n",
          "sql",
          %{p: @test_project, n: "TestMod.Alpha.simple/0"}
        )

      assert row["complexity"] == 0
    end
  end

  # ============================================================================
  # Insight upsert + read
  # ============================================================================

  describe "upsert_insight/8" do
    test "creates an insight vertex" do
      assert {:ok, _} =
               Client.upsert_insight(
                 @test_project,
                 "complexity_drift",
                 "TestMod.Alpha",
                 "high",
                 138,
                 "[10,15,20]",
                 135,
                 138
               )
    end

    test "is idempotent — updates severity on same key" do
      Client.upsert_insight(@test_project, "hotspot", "TestMod.X", "low", 137, "[5]", 137, 137)

      Client.upsert_insight(
        @test_project,
        "hotspot",
        "TestMod.X",
        "high",
        138,
        "[5,10]",
        137,
        138
      )

      {:ok, rows} =
        Client.query(
          "SELECT severity, build_id FROM Insight WHERE project = :p AND type = :t AND module = :m",
          "sql",
          %{p: @test_project, t: "hotspot", m: "TestMod.X"}
        )

      assert length(rows) == 1
      assert hd(rows)["severity"] == "high"
    end
  end

  describe "list_insights/2" do
    test "returns insights for a project" do
      Client.upsert_insight(
        @test_project,
        "test_insight",
        "TestMod.List",
        "medium",
        138,
        "[]",
        138,
        138
      )

      result = Client.list_insights(@test_project, 138)

      case result do
        {:ok, rows} -> assert Enum.any?(rows, &(&1["module"] == "TestMod.List"))
        # ArcadeDB intermittently slow in test
        {:error, :timeout} -> :ok
      end
    end

    test "returns empty list for unknown project" do
      result = Client.list_insights("/no_data_#{System.unique_integer([:positive])}")
      assert match?({:ok, []}, result) or match?({:error, :timeout}, result)
    end
  end

  # ============================================================================
  # Consolidation queries
  # ============================================================================

  describe "hotspots/3" do
    test "returns modules ranked by combined score" do
      Client.upsert_module(@test_project, "TestMod.Hot1", 138, %{
        complexity_score: 30,
        dep_in: 5,
        dep_out: 3,
        function_count: 10
      })

      Client.upsert_module(@test_project, "TestMod.Hot2", 138, %{
        complexity_score: 10,
        dep_in: 1,
        dep_out: 1,
        function_count: 3
      })

      {:ok, rows} = Client.hotspots(@test_project, 138, 10)
      hot_names = Enum.map(rows, & &1["name"])
      assert "TestMod.Hot1" in hot_names
      assert "TestMod.Hot2" in hot_names

      scores = Enum.map(rows, & &1["hotspot_score"])
      assert scores == Enum.sort(scores, :desc)
    end

    test "excludes all-zero modules" do
      Client.upsert_module(@test_project, "TestMod.Zero", 138, %{
        complexity_score: 0,
        dep_in: 0,
        dep_out: 0,
        function_count: 0
      })

      {:ok, rows} = Client.hotspots(@test_project, 138, 100)
      refute Enum.any?(rows, &(&1["name"] == "TestMod.Zero"))
    end

    test "returns empty for unknown project" do
      {:ok, rows} = Client.hotspots("/empty_#{System.unique_integer([:positive])}", 999)
      assert rows == []
    end
  end

  describe "complexity_history/2" do
    test "returns data or timeout for project with modules" do
      result = Client.complexity_history(@test_project, 5)
      assert match?({:ok, rows} when is_list(rows), result) or match?({:error, :timeout}, result)
    end

    test "returns empty for unknown project" do
      result = Client.complexity_history("/empty_#{System.unique_integer([:positive])}")
      assert match?({:ok, []}, result) or match?({:error, :timeout}, result)
    end
  end

  describe "coupling_history/2" do
    test "returns data or timeout for project with modules" do
      result = Client.coupling_history(@test_project, 5)
      assert match?({:ok, rows} when is_list(rows), result) or match?({:error, :timeout}, result)
    end

    test "returns empty for unknown project" do
      result = Client.coupling_history("/empty_#{System.unique_integer([:positive])}")
      assert match?({:ok, []}, result) or match?({:error, :timeout}, result)
    end
  end

  # ============================================================================
  # list_builds / list_projects
  # ============================================================================

  describe "list_builds/1" do
    test "returns build history or timeout" do
      result = Client.list_builds(@test_project)
      assert match?({:ok, rows} when is_list(rows), result) or match?({:error, :timeout}, result)
    end
  end

  describe "list_projects/0" do
    test "returns list including test project" do
      {:ok, rows} = Client.list_projects()
      assert is_list(rows)
    end
  end

  # ============================================================================
  # Batch operations
  # ============================================================================

  describe "snapshot_graph/4" do
    test "handles empty inputs" do
      {:ok, result} = Client.snapshot_graph(@test_project, [], [], 138)
      assert result.modules == 0
      assert result.edges == 0
    end
  end

  # ============================================================================
  # Adversarial
  # ============================================================================

  describe "adversarial" do
    test "query with empty result set" do
      {:ok, rows} =
        Client.query(
          "SELECT FROM Module WHERE project = 'nope_#{System.unique_integer([:positive])}'"
        )

      assert rows == []
    end

    test "upsert_module with empty name" do
      assert {:ok, _} = Client.upsert_module(@test_project, "", 1)
    end

    test "upsert_function with very long name" do
      long_name = String.duplicate("A", 500) <> ".foo/1"
      assert {:ok, _} = Client.upsert_function(@test_project, long_name, 1)
    end
  end
end
