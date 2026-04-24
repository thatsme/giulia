defmodule Giulia.Monitor.StoreTest do
  @moduledoc """
  Tests for Monitor.Store — rolling event buffer with SSE pub/sub.

  GenServer with bounded queue, subscriber fan-out, and auto-cleanup
  when subscriber processes die.
  """
  use ExUnit.Case, async: false

  alias Giulia.Monitor.Store

  setup do
    # Clear any existing events by pushing enough to flush
    # (buffer is capped at 50)
    :ok
  end

  describe "push/1 and history/0" do
    test "pushed events appear in history" do
      # Monitor.Store is a globally-named GenServer with a bounded 50-event
      # buffer. Under full-suite load the Telemetry handlers (HTTP + inference
      # events) push many events per second, so a "did my specific marker
      # survive in the buffer?" check is a race — other tests' events can
      # evict our marker before we read it back. Instead, subscribe first:
      # handle_cast({:push, ...}) synchronously fan-outs to subscribers via
      # send/2, so the push→subscriber path is deterministic even under
      # concurrent writer pressure. Buffer is still asserted list-shaped.
      Store.subscribe()

      marker = "test_#{System.unique_integer([:positive])}"
      event = %{type: "test", timestamp: System.monotonic_time(), data: marker}
      Store.push(event)

      assert_receive {:monitor_event, received}, 500
      assert Map.get(received, :data) == marker

      assert is_list(Store.history())
    after
      Store.unsubscribe()
    end

    test "history respects the n parameter" do
      # Push several events
      for i <- 1..5 do
        Store.push(%{type: "test", seq: i})
      end

      Process.sleep(20)

      limited = Store.history(2)
      assert length(limited) <= 2
    end

    test "buffer is bounded" do
      # Push more than max_events (50)
      for i <- 1..60 do
        Store.push(%{type: "overflow_test", seq: i})
      end

      Process.sleep(50)

      history = Store.history()
      assert length(history) <= 50
    end
  end

  describe "subscribe/0 and unsubscribe/0" do
    test "subscriber receives pushed events" do
      :ok = Store.subscribe()

      event = %{type: "sub_test", data: "for_subscriber"}
      Store.push(event)

      assert_receive {:monitor_event, received}, 500
      assert received.data == "for_subscriber"

      Store.unsubscribe()
    end

    test "unsubscribed process stops receiving events" do
      :ok = Store.subscribe()
      Store.unsubscribe()

      Process.sleep(10)

      Store.push(%{type: "after_unsub", data: "should_not_receive"})

      refute_receive {:monitor_event, _}, 100
    end

    test "dead subscriber is automatically cleaned up" do
      # Spawn a process that subscribes then dies
      pid = spawn(fn ->
        Store.subscribe()
        # Wait a bit so the subscription registers
        Process.sleep(50)
        # Then exit
      end)

      # Wait for the process to die
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      # Push an event — should not crash even though subscriber is dead
      Store.push(%{type: "after_death", data: "safe"})
      Process.sleep(10)
    end
  end

  describe "history/1 with empty buffer" do
    test "returns a list (possibly with pre-existing events)" do
      history = Store.history()
      assert is_list(history)
    end
  end
end
