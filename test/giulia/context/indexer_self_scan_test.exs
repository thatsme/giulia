defmodule Giulia.Context.IndexerSelfScanTest do
  @moduledoc """
  Coverage for `Giulia.Context.Indexer.self_scan?/1` — the predicate that
  short-circuits the recursive sub-mix compile in `ensure_compiled/1`
  (and is mirrored in `Knowledge.Builder.find_beam_directory/1` to fall
  back to the outer mix's build path).

  The fix it gates: `Indexer.scan/1` against the same source tree the
  running BEAM was launched from used to spawn `mix deps.get` + `mix
  compile` subprocesses on that tree, which shared `mix.lock`,
  `deps/`, and `.fetch` markers with the outer Mix process and
  SIGSEGV'd the BEAM (exit 139) on ARM64 / OrbStack with concurrent
  EXLA work — observed every time integration tests scanned
  `/projects/Giulia`. The fix detects self-scan and trusts the outer
  Mix's already-compiled BEAMs.

  Why each adversarial case matters:
    * Drop-side: a refactor that breaks self-scan detection silently
      reintroduces the SIGSEGV.
    * Identity-side: must use canonicalized path equality (Path.expand)
      — trailing slashes / relative paths must compare equal.
    * Defensive: non-binary input must not raise (would crash the
      Indexer post-scan pipeline).
  """

  use ExUnit.Case, async: true

  alias Giulia.Context.Indexer

  describe "self_scan?/1" do
    test "returns true when the path matches the current working directory" do
      cwd = File.cwd!()
      assert Indexer.self_scan?(cwd) == true
    end

    test "returns true with a trailing slash (Path.expand normalizes)" do
      cwd = File.cwd!()
      assert Indexer.self_scan?(cwd <> "/") == true
    end

    test "returns false for a different absolute path" do
      refute Indexer.self_scan?("/definitely/not/the/cwd/xyz_abc")
    end

    test "returns false for a sibling directory of cwd" do
      cwd = File.cwd!()
      sibling = Path.join(Path.dirname(cwd), "definitely-not-this-project")
      refute Indexer.self_scan?(sibling)
    end

    test "returns false (defensive) for non-binary input" do
      # The Indexer post-scan pipeline propagates a path string from
      # Indexer.scan/2 callers, so non-binary inputs shouldn't reach
      # this predicate. But returning false instead of raising means a
      # programming error doesn't crash the Indexer GenServer or its
      # supervised post-scan task.
      refute Indexer.self_scan?(nil)
      refute Indexer.self_scan?(:not_a_path)
      refute Indexer.self_scan?(123)
      refute Indexer.self_scan?(["/some/path"])
    end
  end
end
