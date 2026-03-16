defmodule Giulia.Persistence.LoaderTest do
  use ExUnit.Case

  alias Giulia.Persistence.{Store, Loader}

  @test_dir System.tmp_dir!() |> Path.join("giulia_loader_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)

    # Close and clear any leftover CubDB from previous runs
    Store.close(@test_dir)

    # Clear the hashed temp CubDB directory used in test mode
    hash = :erlang.phash2(@test_dir) |> Integer.to_string()
    cubdb_tmp = Path.join([System.tmp_dir!(), "giulia_test_cubdb", hash])
    File.rm_rf(cubdb_tmp)

    on_exit(fn ->
      Store.close(@test_dir)
      File.rm_rf(cubdb_tmp)
      File.rm_rf!(@test_dir)
    end)
  end

  describe "load_project/1 — cold start" do
    test "returns cold_start when no CubDB exists" do
      assert {:cold_start, :no_cache} = Loader.load_project("/nonexistent/path/#{:rand.uniform(100_000)}")
    end

    test "returns cold_start when CubDB is empty" do
      {:ok, _db} = Store.open(@test_dir)
      assert {:cold_start, :no_cache} = Loader.load_project(@test_dir)
    end
  end

  describe "load_project/1 — warm start" do
    test "restores cached AST entries and detects stale files" do
      {:ok, db} = Store.open(@test_dir)

      # Create a real file on disk
      test_file = Path.join(@test_dir, "valid.ex")
      File.write!(test_file, "defmodule Valid do\nend\n")
      content_hash = :crypto.hash(:sha256, File.read!(test_file))

      # Populate CubDB with matching cached data
      ast_data = %{modules: [%{name: "Valid", line: 1}], functions: []}
      CubDB.put_multi(db, [
        {{:ast, test_file}, ast_data},
        {{:content_hash, test_file}, content_hash},
        {{:meta, :schema_version}, Store.schema_version()},
        {{:meta, :build}, Store.current_build()},
        {{:project_files}, [test_file]}
      ])

      # Also add a stale entry for a deleted file
      CubDB.put(db, {:ast, "/deleted/file.ex"}, %{modules: []})
      CubDB.put(db, {:content_hash, "/deleted/file.ex"}, <<0::256>>)

      result = Loader.load_project(@test_dir)
      assert {:ok, stale} = result
      assert "/deleted/file.ex" in stale
    end

    test "returns cold_start on schema version mismatch" do
      {:ok, db} = Store.open(@test_dir)

      test_file = Path.join(@test_dir, "foo.ex")
      File.write!(test_file, "defmodule Foo, do: nil")

      CubDB.put_multi(db, [
        {{:ast, test_file}, %{modules: []}},
        {{:content_hash, test_file}, :crypto.hash(:sha256, File.read!(test_file))},
        {{:meta, :schema_version}, 9999},
        {{:meta, :build}, Store.current_build()}
      ])

      assert {:cold_start, :no_cache} = Loader.load_project(@test_dir)
    end
  end
end
