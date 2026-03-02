defmodule Giulia.Context.IndexerTest do
  @moduledoc """
  Tests for Context.Indexer — background AST scanner.

  Tests cover: status, ignored path detection, scan triggering.
  Does NOT test full project scanning (side-effects on Store).
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Indexer

  describe "status/0" do
    test "returns a map with expected keys" do
      status = Indexer.status()
      assert is_map(status)
      assert Map.has_key?(status, :status)
      assert Map.has_key?(status, :project_path)
      assert Map.has_key?(status, :file_count)
    end

    test "status is :idle or :scanning" do
      %{status: s} = Indexer.status()
      assert s in [:idle, :scanning]
    end
  end

  describe "ignored_dirs/0" do
    test "returns a list of directory names" do
      dirs = Indexer.ignored_dirs()
      assert is_list(dirs)
      assert "node_modules" in dirs
      assert "_build" in dirs
      assert "deps" in dirs
      assert ".git" in dirs
    end
  end

  describe "ignored?/1" do
    test "returns true for paths containing ignored dirs" do
      assert Indexer.ignored?("/project/node_modules/foo.ex")
      assert Indexer.ignored?("/project/_build/dev/lib/foo.ex")
      assert Indexer.ignored?("/project/deps/jason/lib/jason.ex")
      assert Indexer.ignored?("/project/.git/config")
    end

    test "returns true for ignored file patterns" do
      assert Indexer.ignored?("module.beam")
      assert Indexer.ignored?("code.pyc")
      assert Indexer.ignored?("app.min.js")
      assert Indexer.ignored?("mix.lock")
      assert Indexer.ignored?("package-lock.json")
    end

    test "returns false for normal source files" do
      refute Indexer.ignored?("/project/lib/my_module.ex")
      refute Indexer.ignored?("/project/lib/my_app/server.ex")
      refute Indexer.ignored?("/project/test/my_test.exs")
    end
  end

  describe "scan/1" do
    test "is a cast that returns :ok" do
      # scan is async (cast), should not crash even with bad path
      assert :ok = Indexer.scan("/nonexistent/path")
    end
  end

  describe "index_path/1" do
    test "is an alias for scan/1" do
      assert :ok = Indexer.index_path("/nonexistent/path")
    end
  end

  describe "scan_file/1" do
    test "is a cast that returns :ok" do
      assert :ok = Indexer.scan_file("/nonexistent/file.ex")
    end
  end

  describe "index_file/1" do
    test "is an alias for scan_file/1" do
      assert :ok = Indexer.index_file("/nonexistent/file.ex")
    end
  end
end
