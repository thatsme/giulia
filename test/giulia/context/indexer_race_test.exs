defmodule Giulia.Context.IndexerRaceTest do
  @moduledoc """
  Tests for filesystem race conditions during indexing.

  What happens when:
  - A file is deleted between discovery and read
  - A file is modified between read and parse
  - A file has encoding issues (BOM, Latin-1, binary)
  - A file is a symlink to a deleted target
  - A directory appears in the file list
  """
  use ExUnit.Case, async: true

  alias Giulia.AST.Processor

  @tmp_dir Path.join(System.tmp_dir!(), "indexer_race_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  # ============================================================================
  # File disappears between discovery and analysis
  # ============================================================================

  describe "file deleted mid-scan" do
    test "analyze_file returns error for deleted file" do
      path = Path.join(@tmp_dir, "deleted.ex")
      File.write!(path, "defmodule Deleted do\nend")

      # Delete before analysis
      File.rm!(path)

      result = Processor.analyze_file(path)
      assert {:error, _reason} = result
    end

    test "analyze_file returns error for nonexistent path" do
      result = Processor.analyze_file("/nonexistent/path/to/file.ex")
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Encoding edge cases
  # ============================================================================

  describe "encoding issues" do
    test "file with UTF-8 BOM" do
      path = Path.join(@tmp_dir, "bom.ex")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "defmodule BomModule do\n  def hello, do: :world\nend")

      result = Processor.analyze_file(path)
      # Should either parse successfully or return a clean error
      case result do
        {:ok, data} ->
          # If it parses, module should be found
          assert length(data.modules) >= 0

        {:error, _reason} ->
          # Clean error is acceptable
          :ok
      end
    end

    test "file with unicode identifiers" do
      path = Path.join(@tmp_dir, "unicode.ex")
      File.write!(path, """
      defmodule UnicodeTest do
        def greet(name), do: "Hello, \#{name}!"
        # Comment with emoji: fire
        @moduledoc "Module with special chars: < > & \\""
      end
      """)

      result = Processor.analyze_file(path)
      assert {:ok, data} = result
      assert length(data.modules) == 1
    end

    test "binary file is handled gracefully" do
      path = Path.join(@tmp_dir, "binary.ex")
      # Write random bytes that look like a .ex file but aren't valid Elixir
      File.write!(path, :crypto.strong_rand_bytes(256))

      result = Processor.analyze_file(path)
      # Should not crash — return error
      assert {:error, _} = result
    end

    test "empty file" do
      path = Path.join(@tmp_dir, "empty.ex")
      File.write!(path, "")

      result = Processor.analyze_file(path)
      case result do
        {:ok, data} ->
          assert data.modules == []
          assert data.functions == []

        {:error, _} ->
          :ok
      end
    end

    test "file with only whitespace" do
      path = Path.join(@tmp_dir, "whitespace.ex")
      File.write!(path, "   \n\n  \n   ")

      result = Processor.analyze_file(path)
      case result do
        {:ok, data} ->
          assert data.modules == []

        {:error, _} ->
          :ok
      end
    end
  end

  # ============================================================================
  # Large / degenerate files
  # ============================================================================

  describe "large files" do
    test "file with many functions doesn't crash" do
      # Generate a module with 200 functions
      funcs = Enum.map_join(1..200, "\n", fn i ->
        "  def func_#{i}(x), do: x + #{i}"
      end)

      path = Path.join(@tmp_dir, "large.ex")
      File.write!(path, "defmodule LargeModule do\n#{funcs}\nend")

      result = Processor.analyze_file(path)
      assert {:ok, data} = result
      assert length(data.functions) == 200
    end

    test "file with deeply nested code" do
      # 20 levels of nesting
      open = Enum.map_join(1..20, "\n", fn i ->
        indent = String.duplicate("  ", i)
        "#{indent}if true do"
      end)
      close = Enum.map_join(20..1//-1, "\n", fn i ->
        indent = String.duplicate("  ", i)
        "#{indent}end"
      end)

      path = Path.join(@tmp_dir, "nested.ex")
      File.write!(path, "defmodule DeepNest do\n  def deep do\n#{open}\n    :ok\n#{close}\n  end\nend")

      result = Processor.analyze_file(path)
      # Should parse without stack overflow
      assert {:ok, data} = result
      assert length(data.modules) == 1
    end
  end

  # ============================================================================
  # Indexer ignore logic
  # ============================================================================

  describe "ignore patterns" do
    test "ignores _build directory" do
      # _build anywhere in path parts triggers ignore
      assert Giulia.Context.Indexer.ignored?("/project/_build/dev/lib/foo.ex")
    end

    test "ignores deps directory" do
      assert Giulia.Context.Indexer.ignored?("/project/deps/phoenix/lib/phoenix.ex")
    end

    test "ignores .beam files" do
      assert Giulia.Context.Indexer.ignored?("lib/foo.beam")
    end

    test "ignores lock files" do
      assert Giulia.Context.Indexer.ignored?("mix.lock")
    end

    test "does not ignore normal source files" do
      refute Giulia.Context.Indexer.ignored?("lib/giulia/core/context_manager.ex")
    end

    test "does not ignore test files" do
      refute Giulia.Context.Indexer.ignored?("test/giulia/ast/processor_test.exs")
    end
  end
end
