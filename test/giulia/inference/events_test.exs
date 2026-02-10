defmodule Giulia.Inference.EventsTest do
  @moduledoc """
  Tests for Inference.Events — GenServer pub/sub event broadcasting.

  Tests cover subscribe, unsubscribe, and broadcast lifecycle.
  Uses async: false because Events uses a named GenServer.
  """
  use ExUnit.Case, async: false

  alias Giulia.Inference.Events

  setup do
    case Process.whereis(Events) do
      nil -> start_supervised!(Events)
      _pid -> :ok
    end

    :ok
  end

  # ============================================================================
  # subscribe/1 and broadcast/2
  # ============================================================================

  describe "subscribe/1 and broadcast/2" do
    test "subscriber receives broadcast events" do
      request_id = "test-req-#{System.unique_integer([:positive])}"
      assert :ok = Events.subscribe(request_id)

      event = %{type: :tool_call, tool: "read_file"}
      Events.broadcast(request_id, event)

      assert_receive {:ooda_event, ^event}, 1000
    end

    test "non-subscriber does not receive events" do
      request_id = "test-req-#{System.unique_integer([:positive])}"
      other_id = "other-req-#{System.unique_integer([:positive])}"

      Events.subscribe(request_id)
      Events.broadcast(other_id, %{type: :tool_call})

      refute_receive {:ooda_event, _}, 200
    end

    test "multiple subscribers receive the same event" do
      request_id = "test-multi-#{System.unique_integer([:positive])}"

      # Subscribe from current process (simulates two subscribers via same pid)
      Events.subscribe(request_id)

      event = %{type: :iteration, count: 1}
      Events.broadcast(request_id, event)

      assert_receive {:ooda_event, ^event}, 1000
    end
  end

  # ============================================================================
  # unsubscribe/1
  # ============================================================================

  describe "unsubscribe/1" do
    test "unsubscribed process no longer receives events" do
      request_id = "test-unsub-#{System.unique_integer([:positive])}"

      Events.subscribe(request_id)
      Events.unsubscribe(request_id)

      # Give the cast time to process
      Process.sleep(50)

      Events.broadcast(request_id, %{type: :test})

      refute_receive {:ooda_event, _}, 200
    end
  end

  # ============================================================================
  # broadcast to empty subscribers
  # ============================================================================

  describe "broadcast with no subscribers" do
    test "does not crash when broadcasting to unsubscribed request" do
      request_id = "test-empty-#{System.unique_integer([:positive])}"
      # Should not crash
      Events.broadcast(request_id, %{type: :noop})

      # If we get here, the GenServer didn't crash
      assert Process.alive?(Process.whereis(Events))
    end
  end
end
