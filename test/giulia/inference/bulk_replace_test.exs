defmodule Giulia.Inference.BulkReplaceTest do
  @moduledoc """
  Tests for Inference.BulkReplace — batch find-and-replace.

  Tests cover validation, extract_broad_pattern/1, and the full
  execute/3 flow using temp files for I/O.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.{BulkReplace, Transaction}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp with_temp_files(file_contents) do
    dir = System.tmp_dir!()
    prefix = "bulk_replace_test_#{System.unique_integer([:positive])}"

    Enum.map(file_contents, fn {name, content} ->
      path = Path.join(dir, "#{prefix}_#{name}")
      File.write!(path, content)
      path
    end)
  end

  # ============================================================================
  # extract_broad_pattern/1
  # ============================================================================

  describe "extract_broad_pattern/1" do
    test "extracts function prefix from def pattern" do
      assert "def run(" = BulkReplace.extract_broad_pattern("def run(x, y, z)")
    end

    test "extracts function name from dotted call" do
      assert "execute(" = BulkReplace.extract_broad_pattern("Module.execute(arg1, arg2)")
    end

    test "returns pattern unchanged when no special structure" do
      assert "plain text" = BulkReplace.extract_broad_pattern("plain text")
    end

    test "handles def with complex args" do
      assert "def process(" = BulkReplace.extract_broad_pattern("def process(state, %{key: val})")
    end

    test "handles nested module calls" do
      assert "query(" = BulkReplace.extract_broad_pattern("MyApp.Repo.query(sql, params)")
    end
  end

  # ============================================================================
  # execute/3 — validation
  # ============================================================================

  describe "execute/3 validation" do
    test "returns error for empty pattern" do
      params = %{"pattern" => "", "replacement" => "new", "file_list" => ["a.ex"]}
      assert {:error, msg} = BulkReplace.execute(params, Transaction.new(), [])
      assert String.contains?(msg, "pattern")
    end

    test "returns error for nil replacement" do
      params = %{"pattern" => "old", "replacement" => nil, "file_list" => ["a.ex"]}
      assert {:error, msg} = BulkReplace.execute(params, Transaction.new(), [])
      assert String.contains?(msg, "replacement")
    end

    test "returns error for empty file_list" do
      params = %{"pattern" => "old", "replacement" => "new", "file_list" => []}
      assert {:error, msg} = BulkReplace.execute(params, Transaction.new(), [])
      assert String.contains?(msg, "file_list")
    end
  end

  # ============================================================================
  # execute/3 — literal replacement
  # ============================================================================

  describe "execute/3 literal replacement" do
    test "replaces pattern in files" do
      paths = with_temp_files([
        {"a.ex", "def old_func(x), do: x"},
        {"b.ex", "def other(x), do: old_func(x)"}
      ])

      tx = Transaction.new(true)
      opts = [
        project_path: System.tmp_dir!(),
        resolve_fn: &Function.identity/1,
        modified_files: MapSet.new()
      ]

      params = %{
        "pattern" => "old_func",
        "replacement" => "new_func",
        "file_list" => paths
      }

      assert {:ok, observation, new_tx, _modified, meta} = BulkReplace.execute(params, tx, opts)
      assert String.contains?(observation, "BULK_REPLACE")
      assert meta.total_replacements >= 2
      assert map_size(new_tx.staging_buffer) >= 1
    end

    test "reports no matches when pattern not found" do
      paths = with_temp_files([
        {"a.ex", "def run(x), do: x"}
      ])

      tx = Transaction.new(true)
      opts = [
        project_path: System.tmp_dir!(),
        resolve_fn: &Function.identity/1,
        modified_files: MapSet.new()
      ]

      params = %{
        "pattern" => "nonexistent_pattern",
        "replacement" => "new",
        "file_list" => paths
      }

      assert {:ok, observation, _tx, _mf, meta} = BulkReplace.execute(params, tx, opts)
      assert String.contains?(observation, "FAILED")
      assert meta.total_replacements == 0
    end
  end

  # ============================================================================
  # execute/3 — regex replacement
  # ============================================================================

  describe "execute/3 regex replacement" do
    test "replaces using regex pattern" do
      paths = with_temp_files([
        {"a.ex", "def run_v1(x), do: x\ndef run_v2(y), do: y"}
      ])

      tx = Transaction.new(true)
      opts = [
        project_path: System.tmp_dir!(),
        resolve_fn: &Function.identity/1,
        modified_files: MapSet.new()
      ]

      params = %{
        "pattern" => "run_v\\d+",
        "replacement" => "execute",
        "file_list" => paths,
        "regex" => true
      }

      assert {:ok, _observation, new_tx, _mf, meta} = BulkReplace.execute(params, tx, opts)
      assert meta.total_replacements >= 2

      [staged_content] = Map.values(new_tx.staging_buffer)
      assert String.contains?(staged_content, "execute")
      refute String.contains?(staged_content, "run_v1")
    end

    test "returns error for invalid regex" do
      params = %{
        "pattern" => "[invalid",
        "replacement" => "new",
        "file_list" => ["a.ex"],
        "regex" => true
      }

      tx = Transaction.new(true)
      opts = [
        project_path: System.tmp_dir!(),
        resolve_fn: &Function.identity/1,
        modified_files: MapSet.new()
      ]

      assert {:error, msg} = BulkReplace.execute(params, tx, opts)
      assert String.contains?(msg, "Invalid regex")
    end
  end

  # ============================================================================
  # execute/3 — staging buffer overlay
  # ============================================================================

  describe "execute/3 staging overlay" do
    test "uses staged content over disk content" do
      paths = with_temp_files([
        {"a.ex", "original content"}
      ])

      [path] = paths

      # Pre-stage different content
      tx = %Transaction{
        mode: true,
        staging_buffer: %{path => "staged content with target_word inside"},
        staging_backups: %{}
      }

      opts = [
        project_path: System.tmp_dir!(),
        resolve_fn: &Function.identity/1,
        modified_files: MapSet.new()
      ]

      params = %{
        "pattern" => "target_word",
        "replacement" => "replaced_word",
        "file_list" => [path]
      }

      assert {:ok, _obs, new_tx, _mf, meta} = BulkReplace.execute(params, tx, opts)
      assert meta.total_replacements == 1
      assert String.contains?(new_tx.staging_buffer[path], "replaced_word")
    end
  end
end
