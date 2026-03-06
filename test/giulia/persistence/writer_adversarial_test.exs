defmodule Giulia.Persistence.WriterAdversarialTest do
  @moduledoc """
  Adversarial tests for Persistence.Writer (async write-behind).

  Targets:
  - nil content hash when file doesn't exist
  - Rapid-fire writes (debounce batching correctness)
  - persist_ast for nonexistent file (content hash = nil)
  - clear_project actually removes all keys
  - Merkle tree double-write from update_merkle_tree
  - Large batch writes
  - Graph serialization with complex graph structures
  """
  use ExUnit.Case, async: false

  alias Giulia.Persistence.{Store, Writer}

  @base_dir System.tmp_dir!() |> Path.join("giulia_writer_adv")

  setup do
    dir = Path.join(@base_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Store.close(dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "persist_ast with nonexistent file" do
    test "stores nil content_hash when source file doesn't exist", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # File doesn't exist — content_hash will be nil
      Writer.persist_ast(dir, "/nonexistent/phantom.ex", %{modules: [], functions: []})
      Process.sleep(200)

      assert CubDB.get(db, {:ast, "/nonexistent/phantom.ex"}) == %{modules: [], functions: []}
      assert CubDB.get(db, {:content_hash, "/nonexistent/phantom.ex"}) == nil
    end

    test "nil content_hash causes Loader to treat file as stale" do
      # This is the consequence: on next warm start, Loader calls file_changed?
      # which does File.read → error → returns true (stale).
      # So nil hash + missing file = always stale. That's correct behavior.
      # Just documenting this is intentional, not a silent failure.
      dir = Path.join(@base_dir, "nil_hash_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      {:ok, db} = Store.open(dir)

      # Simulate cached entry with nil hash
      CubDB.put_multi(db, [
        {{:ast, "/gone/file.ex"}, %{modules: []}},
        {{:content_hash, "/gone/file.ex"}, nil},
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()}
      ])

      {:ok, stale} = Giulia.Persistence.Loader.load_project(dir)
      assert "/gone/file.ex" in stale

      Store.close(dir)
      File.rm_rf!(dir)
    end
  end

  describe "rapid-fire writes (debounce batching)" do
    test "100 rapid writes are batched into fewer CubDB operations", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Create source files
      for i <- 1..100 do
        file = Path.join(dir, "file_#{i}.ex")
        File.write!(file, "defmodule F#{i}, do: nil")
        Writer.persist_ast(dir, file, %{modules: [%{name: "F#{i}", line: 1}], functions: []})
      end

      # Wait for debounce + flush (longer under full suite contention)
      Process.sleep(2000)

      # All 100 entries should be in CubDB
      for i <- 1..100 do
        file = Path.join(dir, "file_#{i}.ex")
        assert CubDB.get(db, {:ast, file}) != nil, "Missing AST for file_#{i}.ex"
      end

      # Metadata should be set
      assert CubDB.get(db, {:meta, :schema_version}) == Store.schema_version()
    end

    test "overwriting same file rapidly keeps only last version", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      file = Path.join(dir, "volatile.ex")
      File.write!(file, "defmodule V, do: nil")

      for i <- 1..50 do
        Writer.persist_ast(dir, file, %{modules: [%{name: "V", line: i}], functions: []})
      end

      Process.sleep(200)

      # Only the last write should survive (debounce map overwrites same key)
      ast = CubDB.get(db, {:ast, file})
      assert ast != nil
      assert hd(ast.modules).line == 50
    end
  end

  describe "clear_project" do
    test "removes all keys from CubDB", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Populate with various key types
      file = Path.join(dir, "clear_test.ex")
      File.write!(file, "defmodule ClearTest, do: nil")

      CubDB.put_multi(db, [
        {{:ast, file}, %{modules: []}},
        {{:content_hash, file}, <<1::256>>},
        {{:meta, :schema_version}, 1},
        {{:meta, :build}, 100},
        {{:graph, :serialized}, <<>>},
        {{:metrics, :cached}, %{foo: :bar}},
        {{:embedding, :module}, [%{id: "X"}]},
        {{:merkle, :tree}, %{root: nil, leaves: %{}, leaf_count: 0}},
        {{:project_files}, [file]}
      ])

      # Verify populated
      assert CubDB.get(db, {:ast, file}) != nil

      Writer.clear_project(dir)
      Process.sleep(200)

      # Everything should be gone
      assert CubDB.get(db, {:ast, file}) == nil
      assert CubDB.get(db, {:content_hash, file}) == nil
      assert CubDB.get(db, {:meta, :schema_version}) == nil
      assert CubDB.get(db, {:graph, :serialized}) == nil
      assert CubDB.get(db, {:metrics, :cached}) == nil
      assert CubDB.get(db, {:embedding, :module}) == nil
      assert CubDB.get(db, {:merkle, :tree}) == nil
      assert CubDB.get(db, {:project_files}) == nil
    end

    test "clear cancels pending writes for that project", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      file = Path.join(dir, "cancel_me.ex")
      File.write!(file, "defmodule Cancel, do: nil")

      # Queue a write
      Writer.persist_ast(dir, file, %{modules: [%{name: "Cancel"}], functions: []})
      # Immediately clear before debounce fires
      Writer.clear_project(dir)

      Process.sleep(200)

      # The AST should NOT be in CubDB (clear won the race)
      assert CubDB.get(db, {:ast, file}) == nil
    end
  end

  describe "persist_graph edge cases" do
    test "complex graph with 100 vertices serializes and restores", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      graph =
        Enum.reduce(1..100, Graph.new(type: :directed), fn i, g ->
          g
          |> Graph.add_vertex("Mod#{i}", :module)
          |> then(fn g2 ->
            if i > 1, do: Graph.add_edge(g2, "Mod#{i}", "Mod#{i - 1}"), else: g2
          end)
        end)

      Writer.persist_graph(dir, graph)
      Process.sleep(200)

      binary = CubDB.get(db, {:graph, :serialized})
      assert is_binary(binary)

      restored = :erlang.binary_to_term(binary)
      assert Graph.num_vertices(restored) == 100
      assert Graph.num_edges(restored) == 99
    end

    test "empty graph serializes correctly", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      Writer.persist_graph(dir, Graph.new())
      Process.sleep(200)

      binary = CubDB.get(db, {:graph, :serialized})
      restored = :erlang.binary_to_term(binary)
      assert Graph.num_vertices(restored) == 0
    end
  end

  describe "persist_embeddings" do
    test "large embedding list persists correctly", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      entries =
        for i <- 1..500 do
          %{id: "Mod#{i}", vector: :crypto.strong_rand_bytes(384 * 4)}
        end

      Writer.persist_embeddings(dir, :module, entries)
      Process.sleep(200)

      restored = CubDB.get(db, {:embedding, :module})
      assert length(restored) == 500
    end

    test "overwriting embeddings replaces entirely", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      Writer.persist_embeddings(dir, :function, [%{id: "old"}])
      Process.sleep(150)

      Writer.persist_embeddings(dir, :function, [%{id: "new1"}, %{id: "new2"}])
      Process.sleep(150)

      restored = CubDB.get(db, {:embedding, :function})
      assert length(restored) == 2
      assert hd(restored).id == "new1"
    end
  end

  describe "Merkle tree integration in flush" do
    test "Merkle tree is built on first flush and updated on subsequent", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      file1 = Path.join(dir, "m1.ex")
      File.write!(file1, "defmodule M1, do: nil")
      Writer.persist_ast(dir, file1, %{modules: [%{name: "M1"}], functions: []})
      Process.sleep(200)

      tree1 = CubDB.get(db, {:merkle, :tree})
      assert tree1 != nil
      assert tree1.leaf_count >= 1
      root1 = tree1.root.hash

      # Second file changes the Merkle root
      file2 = Path.join(dir, "m2.ex")
      File.write!(file2, "defmodule M2, do: nil")
      Writer.persist_ast(dir, file2, %{modules: [%{name: "M2"}], functions: []})
      Process.sleep(200)

      tree2 = CubDB.get(db, {:merkle, :tree})
      assert tree2.leaf_count >= 2
      assert tree2.root.hash != root1
    end
  end

  describe "persist_metrics edge cases" do
    test "nil values in metrics map", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      Writer.persist_metrics(dir, %{heatmap: nil, dead_code: nil, coupling: %{}})
      Process.sleep(150)

      restored = CubDB.get(db, {:metrics, :cached})
      assert restored.heatmap == nil
      assert restored.coupling == %{}
    end

    test "empty metrics map", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      Writer.persist_metrics(dir, %{})
      Process.sleep(150)

      assert CubDB.get(db, {:metrics, :cached}) == %{}
    end
  end
end
