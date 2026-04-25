defmodule Giulia.Persistence.LoaderAdversarialTest do
  @moduledoc """
  Adversarial tests for Persistence.Loader (startup recovery).

  Targets:
  - Build downgrade detection (and the nil bypass)
  - Corrupt content hash stored in CubDB
  - File exists but is unreadable (permission denied)
  - CubDB has AST entries but no metadata
  - Partial cache: has graph but no ASTs
  - restore_graph with corrupt ETF binary
  - restore_metrics with non-map value
  - restore_embeddings with non-list value
  - cached_merkle_root edge cases
  """
  use ExUnit.Case, async: false

  alias Giulia.Persistence.{Store, Loader}

  @base_dir System.tmp_dir!() |> Path.join("giulia_loader_adv")

  setup do
    dir = Path.join(@base_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Store.close(dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Helper to populate CubDB with valid metadata + AST entries
  defp seed_cache(db, dir, files \\ []) do
    entries = [
      {{:meta, :schema_version}, Store.schema_version()},
      {{:meta, :build}, Store.current_build()}
    ]

    file_entries =
      Enum.flat_map(files, fn {rel_path, ast_data} ->
        full_path = Path.join(dir, rel_path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, "defmodule X, do: nil")
        content_hash = :crypto.hash(:sha256, File.read!(full_path))

        [
          {{:ast, full_path}, ast_data},
          {{:content_hash, full_path}, content_hash}
        ]
      end)

    CubDB.put_multi(db, entries ++ file_entries)
  end

  # ============================================================================
  # Build downgrade detection
  # ============================================================================

  describe "build downgrade" do
    test "detects stored build > current build", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, 999_999},
        {{:ast, "fake.ex"}, %{modules: []}},
        {{:content_hash, "fake.ex"}, <<0::256>>}
      ])

      assert {:cold_start, :no_cache} = Loader.load_project(dir)
    end

    test "nil stored build triggers cold start (incomplete metadata)", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      file = Path.join(dir, "ok.ex")
      File.write!(file, "defmodule Ok, do: nil")
      hash = :crypto.hash(:sha256, File.read!(file))

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, nil},
        {{:ast, file}, %{modules: [%{name: "Ok", line: 1}], functions: []}},
        {{:content_hash, file}, hash}
      ])

      # nil build is now detected as incomplete metadata → cold start
      assert {:cold_start, :no_cache} = Loader.load_project(dir)
    end
  end

  # ============================================================================
  # Corrupt content hash
  # ============================================================================

  describe "corrupt content hash" do
    test "wrong hash stored → file treated as stale", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      file = Path.join(dir, "tampered.ex")
      File.write!(file, "defmodule Tampered, do: nil")

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()},
        {{:ast, file}, %{modules: []}},
        # Wrong hash — doesn't match file content
        {{:content_hash, file}, <<0::256>>}
      ])

      {:ok, stale} = Loader.load_project(dir)
      assert file in stale
    end

    test "nil hash stored → file treated as stale", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      file = Path.join(dir, "nil_hash.ex")
      File.write!(file, "defmodule NilHash, do: nil")

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()},
        {{:ast, file}, %{modules: []}},
        {{:content_hash, file}, nil}
      ])

      {:ok, stale} = Loader.load_project(dir)
      # nil != sha256(content) → stale
      assert file in stale
    end
  end

  # ============================================================================
  # CubDB has entries but no metadata
  # ============================================================================

  describe "missing metadata" do
    test "AST entries but no schema_version → cold start", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      CubDB.put(db, {:ast, "orphan.ex"}, %{modules: []})
      # No {:meta, :schema_version} key

      assert {:cold_start, :no_cache} = Loader.load_project(dir)
    end

    test "schema_version present but no AST entries → cold start", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()}
      ])

      assert {:cold_start, :no_cache} = Loader.load_project(dir)
    end
  end

  # ============================================================================
  # File permission / read errors
  # ============================================================================

  describe "file read errors during staleness check" do
    test "file that exists but becomes unreadable is treated as stale", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      file = Path.join(dir, "perm.ex")
      File.write!(file, "defmodule Perm, do: nil")
      hash = :crypto.hash(:sha256, File.read!(file))

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()},
        {{:ast, file}, %{modules: []}},
        {{:content_hash, file}, hash}
      ])

      # Remove file — simulates "exists but unreadable" scenario
      # (On Linux we could chmod 000, but rm is portable)
      File.rm!(file)

      {:ok, stale} = Loader.load_project(dir)
      assert file in stale
    end
  end

  # ============================================================================
  # restore_graph adversarial cases
  # ============================================================================

  describe "restore_graph" do
    test "returns :not_cached when no graph stored", %{dir: dir} do
      {:ok, _db} = Store.open(dir)
      assert :not_cached = Loader.restore_graph(dir)
    end

    test "restores valid graph from CubDB", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      graph = Graph.new(type: :directed)
        |> Graph.add_vertex("A", :module)
        |> Graph.add_vertex("B", :module)
        |> Graph.add_edge("A", "B")

      envelope = %{digest: Giulia.Knowledge.CodeDigest.current(), payload: graph}
      binary = :erlang.term_to_binary(envelope, [:compressed])
      CubDB.put(db, {:graph, :serialized}, binary)

      assert :ok = Loader.restore_graph(dir)
    end

    test "stale digest invalidates cached graph", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      graph = Graph.new(type: :directed) |> Graph.add_vertex("X", :module)
      envelope = %{digest: "stale_digest1", payload: graph}
      CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(envelope, [:compressed]))

      assert :not_cached = Loader.restore_graph(dir)
    end

    test "legacy un-versioned graph format degrades to :not_cached", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      graph = Graph.new(type: :directed) |> Graph.add_vertex("A", :module)
      # Old format: raw graph, no envelope
      CubDB.put(db, {:graph, :serialized}, :erlang.term_to_binary(graph, [:compressed]))

      assert :not_cached = Loader.restore_graph(dir)
    end

    test "corrupt ETF binary degrades to :not_cached", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Write garbage binary — :erlang.binary_to_term will raise ArgumentError
      CubDB.put(db, {:graph, :serialized}, <<0, 1, 2, 3, 4, 5>>)

      # Fixed: now rescued and returns :not_cached instead of crashing
      assert :not_cached = Loader.restore_graph(dir)
    end
  end

  # ============================================================================
  # restore_metrics adversarial cases
  # ============================================================================

  describe "restore_metrics" do
    test "returns :not_cached when no metrics stored", %{dir: dir} do
      {:ok, _db} = Store.open(dir)
      assert :not_cached = Loader.restore_metrics(dir)
    end

    test "restores valid metrics", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      metrics = %{heatmap: %{}, dead_code: []}
      envelope = %{digest: Giulia.Knowledge.CodeDigest.current(), payload: metrics}
      CubDB.put(db, {:metrics, :cached}, envelope)

      assert :ok = Loader.restore_metrics(dir)
    end

    test "stale digest invalidates cached metrics", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      envelope = %{digest: "stale_digest1", payload: %{heatmap: %{}, dead_code: []}}
      CubDB.put(db, {:metrics, :cached}, envelope)

      assert :not_cached = Loader.restore_metrics(dir)
    end

    test "legacy un-versioned metrics format degrades to :not_cached", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      # Old format: raw map without digest envelope
      CubDB.put(db, {:metrics, :cached}, %{heatmap: %{}, dead_code: []})

      assert :not_cached = Loader.restore_metrics(dir)
    end

    test "non-map value stored degrades to :not_cached", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Store a list instead of a map
      CubDB.put(db, {:metrics, :cached}, [:not, :a, :map])

      # Fixed: catch-all clause returns :not_cached instead of CaseClauseError
      assert :not_cached = Loader.restore_metrics(dir)
    end
  end

  # ============================================================================
  # restore_embeddings adversarial cases
  # ============================================================================

  describe "restore_embeddings" do
    test "returns :not_cached when no embeddings stored", %{dir: dir} do
      {:ok, _db} = Store.open(dir)
      assert :not_cached = Loader.restore_embeddings(dir)
    end

    test "restores module and function embeddings", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      CubDB.put(db, {:embedding, :module}, [%{id: "Foo", vector: <<1::32>>}])
      CubDB.put(db, {:embedding, :function}, [%{id: "Foo.bar/1", vector: <<2::32>>}])

      assert :ok = Loader.restore_embeddings(dir)
    end

    test "non-list value stored degrades to :not_cached", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Store a map instead of a list
      CubDB.put(db, {:embedding, :module}, %{not: "a list"})

      # Fixed: catch-all clause skips corrupt entry instead of CaseClauseError
      assert :not_cached = Loader.restore_embeddings(dir)
    end
  end

  # ============================================================================
  # cached_merkle_root
  # ============================================================================

  describe "cached_merkle_root" do
    test "returns :not_cached when no tree stored", %{dir: dir} do
      {:ok, _db} = Store.open(dir)
      assert :not_cached = Loader.cached_merkle_root(dir)
    end

    test "returns root hash from cached tree", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      tree = Giulia.Persistence.Merkle.build([{"lib/a.ex", %{x: 1}}])
      CubDB.put(db, {:merkle, :tree}, tree)

      {:ok, hash} = Loader.cached_merkle_root(dir)
      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "empty tree returns nil root hash", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      tree = Giulia.Persistence.Merkle.build([])
      CubDB.put(db, {:merkle, :tree}, tree)

      {:ok, nil} = Loader.cached_merkle_root(dir)
    end
  end

  # ============================================================================
  # Mixed valid + stale entries
  # ============================================================================

  describe "mixed cache quality" do
    test "valid + stale + deleted files classified correctly", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Valid file (hash matches)
      valid_file = Path.join(dir, "valid.ex")
      File.write!(valid_file, "defmodule Valid, do: nil")
      valid_hash = :crypto.hash(:sha256, File.read!(valid_file))

      # Stale file (hash mismatch)
      stale_file = Path.join(dir, "stale.ex")
      File.write!(stale_file, "defmodule Stale, do: :new_version")

      # Deleted file
      deleted_file = Path.join(dir, "deleted.ex")

      CubDB.put_multi(db, [
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()},
        # Valid
        {{:ast, valid_file}, %{modules: [%{name: "Valid"}]}},
        {{:content_hash, valid_file}, valid_hash},
        # Stale (wrong hash)
        {{:ast, stale_file}, %{modules: [%{name: "Stale"}]}},
        {{:content_hash, stale_file}, <<0::256>>},
        # Deleted (file doesn't exist on disk)
        {{:ast, deleted_file}, %{modules: [%{name: "Deleted"}]}},
        {{:content_hash, deleted_file}, <<1::256>>}
      ])

      {:ok, stale} = Loader.load_project(dir)

      # Stale and deleted should be flagged
      assert stale_file in stale
      assert deleted_file in stale
      # Valid should NOT be in stale
      refute valid_file in stale
    end
  end
end
