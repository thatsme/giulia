defmodule Giulia.Inference.ApprovalTest do
  @moduledoc """
  Tests for Inference.Approval — interactive consent gate GenServer.

  Tests cover the sync/async approval flow, respond, list_pending,
  get_pending, cancel, and timeout handling.
  """
  use ExUnit.Case, async: false

  alias Giulia.Inference.Approval

  setup do
    case Process.whereis(Approval) do
      nil -> start_supervised!(Approval)
      _pid -> :ok
    end

    :ok
  end

  # ============================================================================
  # Async approval flow
  # ============================================================================

  describe "request_approval_async/6 and respond/2" do
    test "async approval sends approved message to callback" do
      approval_id = "async-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{"path" => "lib/foo.ex"},
        "Write 100 bytes to foo.ex", self()
      )

      # Respond with approval
      Approval.respond(approval_id, true)

      assert_receive {:approval_response, ^approval_id, :approved}, 2000
    end

    test "async rejection sends rejected message to callback" do
      approval_id = "async-reject-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "edit_file", %{}, "Edit foo.ex", self()
      )

      Approval.respond(approval_id, false)

      assert_receive {:approval_response, ^approval_id, :rejected}, 2000
    end
  end

  # ============================================================================
  # list_pending/0 and get_pending/1
  # ============================================================================

  describe "list_pending/0 and get_pending/1" do
    test "pending request appears in list" do
      approval_id = "list-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{"path" => "test.ex"},
        "Write test.ex", self()
      )

      # Give the cast time to process
      Process.sleep(50)

      pending = Approval.list_pending()
      assert Enum.any?(pending, fn p -> p.request_id == approval_id end)
    end

    test "get_pending returns request info" do
      approval_id = "get-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "patch_function", %{"module" => "Foo"},
        "Patch Foo.run/1", self()
      )

      Process.sleep(50)

      assert {:ok, info} = Approval.get_pending(approval_id)
      assert info.tool == "patch_function"
      assert info.preview == "Patch Foo.run/1"
    end

    test "get_pending returns error for unknown request" do
      assert {:error, :not_found} = Approval.get_pending("nonexistent-id")
    end

    test "responded request is removed from pending" do
      approval_id = "remove-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{}, "preview", self()
      )

      Process.sleep(50)
      Approval.respond(approval_id, true)
      assert_receive {:approval_response, ^approval_id, :approved}, 2000

      Process.sleep(50)
      assert {:error, :not_found} = Approval.get_pending(approval_id)
    end
  end

  # ============================================================================
  # cancel/1
  # ============================================================================

  describe "cancel/1" do
    test "cancel sends timeout message to callback" do
      approval_id = "cancel-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{}, "preview", self()
      )

      Process.sleep(50)
      Approval.cancel(approval_id)

      assert_receive {:approval_response, ^approval_id, {:timeout, :cancelled}}, 2000
    end

    test "cancel removes request from pending" do
      approval_id = "cancel-remove-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{}, "preview", self()
      )

      Process.sleep(50)
      Approval.cancel(approval_id)

      # Give time for processing
      Process.sleep(50)
      assert {:error, :not_found} = Approval.get_pending(approval_id)
    end
  end

  # ============================================================================
  # Timeout handling
  # ============================================================================

  describe "timeout" do
    test "short timeout sends timeout message" do
      approval_id = "timeout-test-#{System.unique_integer([:positive])}"

      Approval.request_approval_async(
        approval_id, "write_file", %{}, "preview", self(),
        timeout: 100
      )

      # Wait for the timeout to fire
      assert_receive {:approval_response, ^approval_id, {:timeout, :deadline_exceeded}}, 2000
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "edge cases" do
    test "responding to unknown request does not crash" do
      Approval.respond("nonexistent-#{System.unique_integer([:positive])}", true)

      # If we get here, the GenServer didn't crash
      Process.sleep(50)
      assert Process.alive?(Process.whereis(Approval))
    end

    test "cancelling unknown request does not crash" do
      Approval.cancel("nonexistent-#{System.unique_integer([:positive])}")

      Process.sleep(50)
      assert Process.alive?(Process.whereis(Approval))
    end
  end
end
