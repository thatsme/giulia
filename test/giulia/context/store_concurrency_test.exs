defmodule Giulia.Context.StoreConcurrencyTest do
  @moduledoc """
  ETS consistency tests under concurrent access.

  These test what happens when multiple processes read/write Store
  simultaneously — the kind of thing that happens in production when
  the indexer is scanning files while an API request queries modules.

  ETS is process-safe for individual operations, but sequences of
  operations (read-modify-write) are NOT atomic. These tests probe
  whether Store's API has such sequences.
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Store

  @project "/tmp/concurrency_test_#{:rand.uniform(100_000)}"

  setup do
    on_exit(fn -> Store.clear_asts(@project) end)
    :ok
  end

  describe "concurrent writes to different files" do
    test "all writes are visible after concurrent put_ast" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            ast_data = %{
              modules: [%{name: "Mod#{i}", line: 1, moduledoc: nil}],
              functions: [%{name: :func, arity: 0, type: :def, line: 2}],
              imports: [], types: [], specs: [], callbacks: [],
              optional_callbacks: [], structs: [], docs: [],
              line_count: 5, complexity: 1
            }

            Store.put_ast(@project, "lib/mod_#{i}.ex", ast_data)
          end)
        end

      Task.await_many(tasks, 5000)

      # All 50 files should be visible
      all = Store.all_asts(@project)
      assert map_size(all) == 50

      # Each file should have its correct module name
      for i <- 1..50 do
        {:ok, data} = Store.get_ast(@project, "lib/mod_#{i}.ex")
        assert hd(data.modules).name == "Mod#{i}"
      end
    end
  end

  describe "concurrent writes to same file" do
    test "last writer wins (no corruption)" do
      # Simulate rapid updates to the same file (e.g., file watcher triggers)
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            ast_data = %{
              modules: [%{name: "Contested", line: 1, moduledoc: nil}],
              functions: [%{name: String.to_atom("version_#{i}"), arity: 0, type: :def, line: 2}],
              imports: [], types: [], specs: [], callbacks: [],
              optional_callbacks: [], structs: [], docs: [],
              line_count: i, complexity: i
            }

            Store.put_ast(@project, "lib/contested.ex", ast_data)
          end)
        end

      Task.await_many(tasks, 5000)

      # File should exist with ONE version (whichever wrote last)
      {:ok, data} = Store.get_ast(@project, "lib/contested.ex")
      assert length(data.modules) == 1
      assert hd(data.modules).name == "Contested"
      # Should have exactly one function, whatever version won
      assert length(data.functions) == 1
    end
  end

  describe "read during write" do
    test "reads never see partial data" do
      # Seed initial data
      Store.put_ast(@project, "lib/target.ex", %{
        modules: [%{name: "Target", line: 1, moduledoc: nil}],
        functions: [%{name: :original, arity: 0, type: :def, line: 2}],
        imports: [], types: [], specs: [], callbacks: [],
        optional_callbacks: [], structs: [], docs: [],
        line_count: 5, complexity: 1
      })

      # Spawn writers that keep overwriting the same key
      writer = Task.async(fn ->
        for i <- 1..100 do
          Store.put_ast(@project, "lib/target.ex", %{
            modules: [%{name: "Target", line: 1, moduledoc: nil}],
            functions: [%{name: String.to_atom("v#{i}"), arity: 0, type: :def, line: 2}],
            imports: [], types: [], specs: [], callbacks: [],
            optional_callbacks: [], structs: [], docs: [],
            line_count: i, complexity: 1
          })
        end
      end)

      # Concurrent readers
      readers =
        for _ <- 1..50 do
          Task.async(fn ->
            for _ <- 1..20 do
              case Store.get_ast(@project, "lib/target.ex") do
                {:ok, data} ->
                  # Data should always be a complete, valid map
                  assert is_list(data.modules)
                  assert is_list(data.functions)
                  assert length(data.modules) == 1
                  assert length(data.functions) == 1
                  :ok

                :error ->
                  # Between clear_asts and put_ast, this is possible
                  :missing
              end
            end
          end)
        end

      Task.await(writer, 5000)
      results = Task.await_many(readers, 5000)
      # All readers should have completed without crashes
      assert length(results) == 50
    end
  end

  describe "clear during read" do
    test "clear_asts during concurrent reads does not crash" do
      # Seed data
      for i <- 1..10 do
        Store.put_ast(@project, "lib/file_#{i}.ex", %{
          modules: [%{name: "Mod#{i}", line: 1, moduledoc: nil}],
          functions: [], imports: [], types: [], specs: [],
          callbacks: [], optional_callbacks: [], structs: [], docs: [],
          line_count: 5, complexity: 1
        })
      end

      # Start readers
      readers =
        for _ <- 1..20 do
          Task.async(fn ->
            for _ <- 1..50 do
              # These should never crash, even if data disappears mid-read
              _all = Store.all_asts(@project)
              _stats = Store.stats(@project)
              _modules = Store.list_modules(@project)
            end

            :ok
          end)
        end

      # Clear in the middle of reads
      Process.sleep(1)
      Store.clear_asts(@project)

      results = Task.await_many(readers, 5000)
      assert Enum.all?(results, fn r -> r == :ok end)
    end
  end

  describe "multi-project isolation" do
    test "concurrent writes to different projects don't leak" do
      project_a = "/tmp/isolation_a_#{System.unique_integer([:positive])}"
      project_b = "/tmp/isolation_b_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        Store.clear_asts(project_a)
        Store.clear_asts(project_b)
      end)

      task_a = Task.async(fn ->
        for i <- 1..20 do
          Store.put_ast(project_a, "lib/a_#{i}.ex", %{
            modules: [%{name: "A.Mod#{i}", line: 1, moduledoc: nil}],
            functions: [], imports: [], types: [], specs: [],
            callbacks: [], optional_callbacks: [], structs: [], docs: [],
            line_count: 5, complexity: 1
          })
        end
      end)

      task_b = Task.async(fn ->
        for i <- 1..20 do
          Store.put_ast(project_b, "lib/b_#{i}.ex", %{
            modules: [%{name: "B.Mod#{i}", line: 1, moduledoc: nil}],
            functions: [], imports: [], types: [], specs: [],
            callbacks: [], optional_callbacks: [], structs: [], docs: [],
            line_count: 5, complexity: 1
          })
        end
      end)

      Task.await_many([task_a, task_b], 5000)

      a_asts = Store.all_asts(project_a)
      b_asts = Store.all_asts(project_b)

      assert map_size(a_asts) == 20
      assert map_size(b_asts) == 20

      # No module from project A should appear in project B
      a_modules = a_asts |> Map.values() |> Enum.flat_map(fn d -> Enum.map(d.modules, & &1.name) end)
      b_modules = b_asts |> Map.values() |> Enum.flat_map(fn d -> Enum.map(d.modules, & &1.name) end)

      assert Enum.all?(a_modules, fn m -> String.starts_with?(m, "A.") end)
      assert Enum.all?(b_modules, fn m -> String.starts_with?(m, "B.") end)

    end
  end
end
