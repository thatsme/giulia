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

    test "status is :idle, :scanning, or :empty" do
      %{status: s} = Indexer.status()
      assert s in [:idle, :scanning, :empty]
    end
  end

  describe "valid_project_root?/1 + project_markers/0" do
    # These are the hooks `/api/index/scan` uses to reject bad paths
    # with a 422 before dispatching a cast the Indexer would silently
    # refuse. Pin the contract so the HTTP layer stays in sync.
    test "project_markers/0 returns the canonical marker list" do
      markers = Indexer.project_markers()
      assert is_list(markers)
      assert "mix.exs" in markers
      assert "GIULIA.md" in markers
      assert "package.json" in markers
      assert "Cargo.toml" in markers
      assert "go.mod" in markers
    end

    test "valid_project_root?/1 returns false for nil, non-binary, and missing paths" do
      refute Indexer.valid_project_root?(nil)
      refute Indexer.valid_project_root?(:not_a_path)
      refute Indexer.valid_project_root?(42)
      refute Indexer.valid_project_root?("/definitely/does/not/exist/#{System.unique_integer([:positive])}")
    end

    test "valid_project_root?/1 returns true when a project marker exists" do
      tmp = Path.join(System.tmp_dir!(), "giulia_valid_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "# marker")

      try do
        assert Indexer.valid_project_root?(tmp)
      after
        File.rm_rf!(tmp)
      end
    end

    test "valid_project_root?/1 returns false for a directory without any marker" do
      tmp = Path.join(System.tmp_dir!(), "giulia_no_marker_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      try do
        refute Indexer.valid_project_root?(tmp)
      after
        File.rm_rf!(tmp)
      end
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

  describe "ignored?/1 — drop-side accountability" do
    # Parametric: every entry in @ignore_dirs must drop a path that lives
    # under it. The existing test hard-coded 4 dirs and missed silent
    # drift if someone added a new entry without updating the test; this
    # version iterates the live list so coverage stays in sync with
    # additions.
    for dir <- Giulia.Context.Indexer.ignored_dirs() do
      @tag dir: dir
      test "drops paths inside ignored dir #{inspect(dir)}", %{dir: dir} do
        assert Indexer.ignored?("/project/#{dir}/foo.ex"),
               "dir #{inspect(dir)} is in @ignore_dirs but ignored?/1 did not drop a path inside it"
      end
    end

    # Parametric over the sample of ignored file-extension patterns from
    # @ignore_patterns. We anchor on real canonical filenames rather than
    # introspecting the regex list (which would require exposing it).
    @pattern_fixtures [
      "module.beam",
      "code.pyc",
      "Foo.class",
      "native.o",
      "native.so",
      "plugin.dll",
      "app.min.js",
      "bundle.js.map",
      "mix.lock",
      "yarn.lock",
      "package-lock.json"
    ]
    for fixture <- @pattern_fixtures do
      @tag fixture: fixture
      test "drops file matching pattern fixture #{inspect(fixture)}", %{fixture: fixture} do
        assert Indexer.ignored?(fixture),
               "fixture #{inspect(fixture)} should match an @ignore_patterns regex"
      end
    end
  end

  describe "ignored?/1 — pass-through accountability" do
    # Counterpart to the drop-side tests: a diverse set of paths that
    # MUST survive the filter. Historically this was three hand-picked
    # cases; if someone adds an overzealous ignore entry that catches
    # real source files, the filter silently loses them. The pass-
    # through list is the half that catches that regression.
    @pass_through_fixtures [
      "/project/lib/my_module.ex",
      "/project/lib/deep/nested/module.ex",
      "/project/lib/my_app/server.ex",
      "/project/test/my_test.exs",
      "/project/test/giulia/knowledge/builder_test.exs",
      "/project/config/runtime.exs",
      "/project/mix.exs",
      "/project/priv/repo/migrations/20250101_create_users.exs",
      # File named like an ignored suffix but not actually matching
      "/project/lib/beam_counter.ex",
      "/project/lib/pyc_detector.ex",
      "/project/lib/json/parser.ex",
      # Project root with a hyphen in the name (edge case)
      "/some-monorepo/apps/my_app/lib/my_app.ex",
      # Single-letter names
      "/project/lib/a.ex",
      "/project/test/b.exs"
    ]
    for fixture <- @pass_through_fixtures do
      @tag fixture: fixture
      test "passes through #{inspect(fixture)}", %{fixture: fixture} do
        refute Indexer.ignored?(fixture),
               "#{inspect(fixture)} should survive the filter; something in the ignore lists is over-matching"
      end
    end

    test "pass-through sample is larger than drop fixtures" do
      # Sanity check: if someone removes pass-through fixtures while
      # growing the drop fixtures, the N-K balance the dialogue argued
      # for degrades. Keep the asymmetry documented.
      assert length(@pass_through_fixtures) >= length(@pattern_fixtures)
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
