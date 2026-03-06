defmodule Giulia.Persistence.StoreAdversarialTest do
  @moduledoc """
  Adversarial tests for Persistence.Store (CubDB lifecycle manager).

  Targets:
  - Concurrent opens from multiple processes
  - Open after close (re-open)
  - Paths that trigger mkdir_p! failures
  - DB pid validity after close
  - Compaction on empty/populated DB
  """
  use ExUnit.Case, async: false

  alias Giulia.Persistence.Store

  @base_dir System.tmp_dir!() |> Path.join("giulia_store_adv")

  setup do
    dir = Path.join(@base_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Store.close(dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "concurrent open" do
    test "multiple processes opening same path get same pid", %{dir: dir} do
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> Store.open(dir) end)
        end

      results = Task.await_many(tasks, 5000)
      pids = Enum.map(results, fn {:ok, pid} -> pid end)

      # All should get the same CubDB pid
      assert length(Enum.uniq(pids)) == 1
    end

    test "open different paths concurrently without interference" do
      dirs =
        for i <- 1..5 do
          d = Path.join(@base_dir, "concurrent_#{i}_#{:rand.uniform(100_000)}")
          File.mkdir_p!(d)
          d
        end

      tasks = Enum.map(dirs, fn d -> Task.async(fn -> Store.open(d) end) end)
      results = Task.await_many(tasks, 5000)

      pids = Enum.map(results, fn {:ok, pid} -> pid end)
      # All should be different pids
      assert length(Enum.uniq(pids)) == 5

      # Cleanup
      Enum.each(dirs, fn d ->
        Store.close(d)
        File.rm_rf!(d)
      end)
    end
  end

  describe "re-open after close" do
    test "can open, close, and re-open", %{dir: dir} do
      {:ok, pid1} = Store.open(dir)
      assert Process.alive?(pid1)

      Store.close(dir)
      # CubDB pid is stopped
      refute Process.alive?(pid1)

      {:ok, pid2} = Store.open(dir)
      assert Process.alive?(pid2)
      # New pid after re-open
      assert pid1 != pid2
    end

    test "data survives close and re-open", %{dir: dir} do
      {:ok, db} = Store.open(dir)
      CubDB.put(db, :test_key, "hello")
      assert CubDB.get(db, :test_key) == "hello"

      Store.close(dir)
      {:ok, db2} = Store.open(dir)

      # Data persisted on disk
      assert CubDB.get(db2, :test_key) == "hello"
    end
  end

  describe "get_db after close" do
    test "get_db lazily re-opens after close", %{dir: dir} do
      {:ok, _} = Store.open(dir)
      Store.close(dir)

      # get_db should re-open
      {:ok, db} = Store.get_db(dir)
      assert Process.alive?(db)
    end
  end

  describe "compaction" do
    test "compact on empty DB succeeds", %{dir: dir} do
      {:ok, _} = Store.open(dir)
      assert :ok = Store.compact(dir)
    end

    test "compact on populated DB succeeds", %{dir: dir} do
      {:ok, db} = Store.open(dir)

      # Write some data
      for i <- 1..100 do
        CubDB.put(db, {:test, i}, %{data: String.duplicate("x", 100)})
      end

      assert :ok = Store.compact(dir)

      # Data survives compaction
      assert CubDB.get(db, {:test, 50}) == %{data: String.duplicate("x", 100)}
    end
  end

  describe "schema_version and current_build" do
    test "schema_version is a positive integer" do
      assert Store.schema_version() >= 1
    end

    test "current_build returns an integer" do
      build = Store.current_build()
      assert is_integer(build)
      assert build > 0
    end
  end
end
