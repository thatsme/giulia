defmodule Giulia.Persistence.StoreTest do
  use ExUnit.Case

  alias Giulia.Persistence.Store

  @test_dir System.tmp_dir!() |> Path.join("giulia_store_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      Store.close(@test_dir)
      File.rm_rf!(@test_dir)
    end)
  end

  describe "open/1 and get_db/1" do
    test "opens a CubDB instance for a project path" do
      assert {:ok, db} = Store.open(@test_dir)
      assert is_pid(db)
    end

    test "open is idempotent — returns same pid" do
      {:ok, db1} = Store.open(@test_dir)
      {:ok, db2} = Store.open(@test_dir)
      assert db1 == db2
    end

    test "get_db opens lazily" do
      {:ok, db} = Store.get_db(@test_dir)
      assert is_pid(db)
    end
  end

  describe "close/1" do
    test "closes a CubDB instance" do
      {:ok, _db} = Store.open(@test_dir)
      assert :ok = Store.close(@test_dir)
    end

    test "closing non-existent project is a no-op" do
      assert :ok = Store.close("/nonexistent/path")
    end
  end

  describe "schema_version/0" do
    test "returns a positive integer" do
      assert Store.schema_version() >= 1
    end
  end
end
