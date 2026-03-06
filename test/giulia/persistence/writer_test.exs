defmodule Giulia.Persistence.WriterTest do
  use ExUnit.Case

  alias Giulia.Persistence.{Store, Writer}

  @test_dir System.tmp_dir!() |> Path.join("giulia_writer_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)

    # Create a fake source file for content hashing
    test_file = Path.join(@test_dir, "test.ex")
    File.write!(test_file, "defmodule Test do\nend\n")

    on_exit(fn ->
      Store.close(@test_dir)
      File.rm_rf!(@test_dir)
    end)

    %{test_file: test_file}
  end

  describe "persist_ast/3" do
    test "batches writes and flushes to CubDB", %{test_file: test_file} do
      {:ok, db} = Store.open(@test_dir)
      ast_data = %{modules: [%{name: "Test", line: 1}], functions: []}

      Writer.persist_ast(@test_dir, test_file, ast_data)

      # Wait for debounce (100ms) + Task flush + CubDB write
      # Under full test suite load, CubDB can be slow
      Process.sleep(1000)

      # Verify data landed in CubDB
      assert CubDB.get(db, {:ast, test_file}) == ast_data
      assert CubDB.get(db, {:content_hash, test_file}) != nil
      assert CubDB.get(db, {:meta, :schema_version}) != nil
      assert CubDB.get(db, {:meta, :build}) != nil
    end
  end

  describe "persist_graph/2" do
    test "persists graph as compressed ETF" do
      {:ok, db} = Store.open(@test_dir)
      graph = Graph.new(type: :directed) |> Graph.add_vertex("A")

      Writer.persist_graph(@test_dir, graph)
      Process.sleep(500)

      binary = CubDB.get(db, {:graph, :serialized})
      assert is_binary(binary)
      restored = :erlang.binary_to_term(binary)
      assert Graph.num_vertices(restored) == 1
    end
  end

  describe "persist_metrics/2" do
    test "persists metric map" do
      {:ok, _db} = Store.open(@test_dir)
      metrics = %{heatmap: %{}, dead_code: []}

      Writer.persist_metrics(@test_dir, metrics)
      Process.sleep(1000)

      # Re-fetch db pid to avoid stale reference after Task write
      {:ok, db} = Store.get_db(@test_dir)
      assert CubDB.get(db, {:metrics, :cached}) == metrics
    end
  end
end
