defmodule Giulia.Inference.TransactionTest do
  @moduledoc """
  Tests for Inference.Transaction — pure-functional staging logic.

  Tests cover struct construction, staging operations (write, edit),
  read-with-overlay, format helpers, backup tracking, and reporting.
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.Transaction

  # ============================================================================
  # Constructor
  # ============================================================================

  describe "new/1" do
    test "creates transaction with mode off by default" do
      tx = Transaction.new()
      refute tx.mode
      assert tx.staging_buffer == %{}
      assert tx.staging_backups == %{}
      assert tx.lock_count == 0
    end

    test "creates transaction with mode on" do
      tx = Transaction.new(true)
      assert tx.mode
    end
  end

  # ============================================================================
  # stage_write/3
  # ============================================================================

  describe "stage_write/3" do
    test "stages content in buffer" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {result, tx} = Transaction.stage_write(tx, %{"path" => "/tmp/test.ex", "content" => "hello"}, resolve_fn)

      assert {:ok, msg} = result
      assert String.contains?(msg, "5 bytes")
      assert Map.has_key?(tx.staging_buffer, "/tmp/test.ex")
      assert tx.staging_buffer["/tmp/test.ex"] == "hello"
    end

    test "creates backup for original file" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {_result, tx} = Transaction.stage_write(tx, %{"path" => "/nonexistent/file.ex", "content" => "new"}, resolve_fn)

      # File doesn't exist, so backup should be :new_file
      assert Map.has_key?(tx.staging_backups, "/nonexistent/file.ex")
      assert tx.staging_backups["/nonexistent/file.ex"] == :new_file
    end

    test "overwrites previous staged content" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {_, tx} = Transaction.stage_write(tx, %{"path" => "/tmp/test.ex", "content" => "first"}, resolve_fn)
      {_, tx} = Transaction.stage_write(tx, %{"path" => "/tmp/test.ex", "content" => "second"}, resolve_fn)

      assert tx.staging_buffer["/tmp/test.ex"] == "second"
    end

    test "uses resolve_fn to map paths" do
      tx = Transaction.new(true)
      resolve_fn = fn path -> "/resolved" <> path end

      {_, tx} = Transaction.stage_write(tx, %{"path" => "/test.ex", "content" => "data"}, resolve_fn)

      assert Map.has_key?(tx.staging_buffer, "/resolved/test.ex")
    end

    test "handles atom keys in params" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {result, _tx} = Transaction.stage_write(tx, %{path: "/test.ex", content: "data"}, resolve_fn)
      assert {:ok, _} = result
    end
  end

  # ============================================================================
  # stage_edit/3
  # ============================================================================

  describe "stage_edit/3" do
    test "applies edit to previously staged content" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      # First stage a write
      {_, tx} = Transaction.stage_write(tx, %{"path" => "/test.ex", "content" => "hello world"}, resolve_fn)

      # Then edit it
      params = %{"file" => "/test.ex", "old_text" => "hello", "new_text" => "goodbye"}
      {result, tx} = Transaction.stage_edit(tx, params, resolve_fn)

      assert {:ok, _msg} = result
      assert tx.staging_buffer["/test.ex"] == "goodbye world"
    end

    test "returns error when old_text not found" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {_, tx} = Transaction.stage_write(tx, %{"path" => "/test.ex", "content" => "hello world"}, resolve_fn)

      params = %{"file" => "/test.ex", "old_text" => "nonexistent", "new_text" => "replacement"}
      {result, _tx} = Transaction.stage_edit(tx, params, resolve_fn)

      assert {:error, msg} = result
      assert String.contains?(msg, "old_text not found")
    end

    test "returns error when file not found" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      params = %{"file" => "/nonexistent/file.ex", "old_text" => "old", "new_text" => "new"}
      {result, _tx} = Transaction.stage_edit(tx, params, resolve_fn)

      assert {:error, msg} = result
      assert String.contains?(msg, "File not found") or String.contains?(msg, "old_text not found")
    end

    test "replaces only first occurrence (global: false)" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {_, tx} = Transaction.stage_write(tx, %{"path" => "/test.ex", "content" => "aaa bbb aaa"}, resolve_fn)

      params = %{"file" => "/test.ex", "old_text" => "aaa", "new_text" => "ccc"}
      {_, tx} = Transaction.stage_edit(tx, params, resolve_fn)

      assert tx.staging_buffer["/test.ex"] == "ccc bbb aaa"
    end
  end

  # ============================================================================
  # read_with_overlay/2
  # ============================================================================

  describe "read_with_overlay/2" do
    test "returns staged content when available" do
      tx = Transaction.new(true)
      resolve_fn = &Function.identity/1

      {_, tx} = Transaction.stage_write(tx, %{"path" => "/test.ex", "content" => "staged data"}, resolve_fn)

      assert "staged data" = Transaction.read_with_overlay(tx, "/test.ex")
    end

    test "returns nil when path not in staging buffer" do
      tx = Transaction.new()
      assert is_nil(Transaction.read_with_overlay(tx, "/nonexistent.ex"))
    end
  end

  # ============================================================================
  # format_staged_files/1
  # ============================================================================

  describe "format_staged_files/1" do
    test "reports empty staging buffer" do
      tx = Transaction.new()
      result = Transaction.format_staged_files(tx)
      assert String.contains?(result, "No files staged")
    end

    test "reports staged files with sizes" do
      tx = %Transaction{
        mode: true,
        staging_buffer: %{
          "/lib/foo.ex" => "hello world",
          "/lib/bar.ex" => "short"
        }
      }

      result = Transaction.format_staged_files(tx)
      assert String.contains?(result, "STAGED FILES (2)")
      assert String.contains?(result, "/lib/bar.ex")
      assert String.contains?(result, "/lib/foo.ex")
      assert String.contains?(result, "bytes")
    end

    test "includes transaction mode status" do
      tx = %Transaction{mode: true, staging_buffer: %{}}
      result = Transaction.format_staged_files(tx)
      assert String.contains?(result, "Transaction mode: true")
    end
  end

  # ============================================================================
  # backup_original/2
  # ============================================================================

  describe "backup_original/2" do
    test "backs up as :new_file when file doesn't exist" do
      tx = Transaction.new()
      tx = Transaction.backup_original(tx, "/nonexistent/path.ex")
      assert tx.staging_backups["/nonexistent/path.ex"] == :new_file
    end

    test "does not overwrite existing backup" do
      tx = %Transaction{staging_backups: %{"/test.ex" => "original content"}}
      tx = Transaction.backup_original(tx, "/test.ex")
      assert tx.staging_backups["/test.ex"] == "original content"
    end
  end

  # ============================================================================
  # success_report/1
  # ============================================================================

  describe "success_report/1" do
    test "reports committed file count" do
      tx = %Transaction{
        staging_buffer: %{
          "/lib/foo.ex" => "content1",
          "/lib/bar.ex" => "content2"
        }
      }

      result = Transaction.success_report(tx)
      assert String.contains?(result, "COMMIT SUCCESS: 2 file(s)")
      assert String.contains?(result, "foo.ex")
      assert String.contains?(result, "bar.ex")
      assert String.contains?(result, "GREEN")
    end

    test "reports single file" do
      tx = %Transaction{staging_buffer: %{"/lib/only.ex" => "data"}}
      result = Transaction.success_report(tx)
      assert String.contains?(result, "1 file(s)")
    end
  end

  # ============================================================================
  # format_fracture_report/1
  # ============================================================================

  describe "format_fracture_report/1" do
    test "formats behaviour-implementer fractures" do
      fractures = %{
        "MyBehaviour" => [
          %{implementer: "ImplA", missing: [{:connect, 1}, {:query, 2}]},
          %{implementer: "ImplB", missing: [{:connect, 1}]}
        ]
      }

      result = Transaction.format_fracture_report(fractures)
      assert String.contains?(result, "BEHAVIOUR MyBehaviour")
      assert String.contains?(result, "ImplA")
      assert String.contains?(result, "connect/1")
      assert String.contains?(result, "query/2")
      assert String.contains?(result, "ImplB")
    end

    test "handles multiple behaviours" do
      fractures = %{
        "BehaviourA" => [%{implementer: "Impl1", missing: [{:run, 0}]}],
        "BehaviourB" => [%{implementer: "Impl2", missing: [{:stop, 1}]}]
      }

      result = Transaction.format_fracture_report(fractures)
      assert String.contains?(result, "BehaviourA")
      assert String.contains?(result, "BehaviourB")
    end

    test "handles empty fracture map" do
      result = Transaction.format_fracture_report(%{})
      assert result == ""
    end
  end

  # ============================================================================
  # restore_disk_content/2
  # ============================================================================

  describe "restore_disk_content/2" do
    test "no-op for nil original" do
      assert :ok = Transaction.restore_disk_content("/any/path", nil)
    end

    test "no-op for error original" do
      assert :ok = Transaction.restore_disk_content("/any/path", {:error, :enoent})
    end
  end
end
