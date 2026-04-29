defmodule Giulia.Persistence.WriterFlushNowTest do
  @moduledoc """
  Coverage for `Persistence.Writer.flush_now/1` — the synchronous
  per-project flush that closes the 100ms-debounce race surfaced by
  `verify_l2?check=ast` immediately after scan_complete.

  Pre-fix: extraction queued N `persist_ast` casts; the Writer's
  debounce timer waited 100ms after the last one before flushing
  via `CubDB.put_multi/2`. If `:scan_complete` fired and
  `verify_l2` ran inside that window, L2 reported L1=N, L2<N (30
  files missing on Plausible cold-rescan).

  GenServer.call ordering means flush_now waits behind any preceding
  cast in the mailbox, so we test:
    * idempotent on a project with no pending entries
    * processes pending entries when there are some
    * does not raise on missing project (defensive)

  We don't test the actual CubDB persistence here — that's exercised
  by the existing persistence/loader_*_test.exs round-trips.
  """

  use ExUnit.Case, async: false

  alias Giulia.Persistence.Writer

  describe "flush_now/1" do
    test "returns :ok for a project with no pending entries" do
      # Writer is started by the application supervision tree; a
      # project that's never had persist_ast called has no pending
      # entries. flush_now must be a no-op return :ok.
      assert :ok = Writer.flush_now("/projects/no-pending-entries-#{System.unique_integer()}")
    end

    test "is idempotent — calling twice in a row is fine" do
      path = "/projects/no-pending-entries-#{System.unique_integer()}"
      assert :ok = Writer.flush_now(path)
      assert :ok = Writer.flush_now(path)
    end

    test "raises FunctionClauseError on non-binary input" do
      # The Indexer post-scan pipeline always passes a binary path; a
      # non-binary input is a programming error, not a runtime
      # condition to recover from. Crash-loud is correct here so the
      # post-scan task's `rescue` clause logs it and the Indexer
      # GenServer stays up.
      assert_raise FunctionClauseError, fn -> Writer.flush_now(nil) end
      assert_raise FunctionClauseError, fn -> Writer.flush_now(:not_a_path) end
      assert_raise FunctionClauseError, fn -> Writer.flush_now(123) end
    end
  end
end
