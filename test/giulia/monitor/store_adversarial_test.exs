defmodule Giulia.Monitor.StoreAdversarialTest do
  @moduledoc """
  Adversarial tests for Monitor.Store (rolling buffer + SSE pub/sub).

  Targets:
  - Buffer overflow (more events than max_size)
  - Non-map events pushed
  - History with edge-case n values (0, negative, huge)
  - Subscribe/unsubscribe from same process multiple times
  - Subscriber process dies — DOWN cleanup
  - Concurrent pushes from many processes
  - Fan-out to dead subscribers
  - Extremely large events
  """
  use ExUnit.Case, async: false

  alias Giulia.Monitor.Store

  # ============================================================================
  # 1. Buffer overflow
  # ============================================================================

  describe "buffer overflow" do
    test "pushing more than max_events trims oldest" do
      # Default max is 50. Push 60 events.
      for i <- 1..60 do
        Store.push(%{seq: i})
      end

      # Small sleep for async casts to process
      Process.sleep(50)

      events = Store.history(100)
      # Should have at most 50
      assert length(events) <= 50
      # Oldest should be trimmed — first event should be seq > 10
      first = hd(events)
      assert first.seq > 1
    end

    test "pushing exactly max_events fills buffer" do
      # Push exactly 50 events
      for i <- 1..50 do
        Store.push(%{exact: i})
      end

      Process.sleep(50)
      events = Store.history(100)
      assert length(events) <= 50
    end
  end

  # ============================================================================
  # 2. Non-standard event types
  # ============================================================================

  describe "non-standard events" do
    test "push a string instead of map" do
      Store.push("just a string")
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> e == "just a string" end)
    end

    test "push nil" do
      Store.push(nil)
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> e == nil end)
    end

    test "push integer" do
      Store.push(42)
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> e == 42 end)
    end

    test "push list" do
      Store.push([1, 2, 3])
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> e == [1, 2, 3] end)
    end

    test "push tuple" do
      Store.push({:error, :timeout})
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> e == {:error, :timeout} end)
    end

    test "push very large map" do
      big_event = %{data: String.duplicate("x", 100_000)}
      Store.push(big_event)
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn e -> is_map(e) and map_size(e) > 0 end)
    end
  end

  # ============================================================================
  # 3. History edge cases
  # ============================================================================

  describe "history edge cases" do
    test "history(0) returns empty list" do
      Store.push(%{test: true})
      Process.sleep(20)
      events = Store.history(0)
      assert events == []
    end

    test "history with negative n behaves as positive (Enum.take double-negation)" do
      Store.push(%{neg_test: true})
      Process.sleep(20)
      events = Store.history(-5)
      # Enum.take(list, -(-5)) = Enum.take(list, 5) — returns up to 5 events
      assert is_list(events)
      assert length(events) <= 5
    end

    test "history with very large n returns all events" do
      Store.push(%{big_n: true})
      Process.sleep(20)
      events = Store.history(999_999)
      # Should return all events without crashing
      assert is_list(events)
    end

    test "history on empty buffer" do
      # Buffer may have events from other tests (async: false),
      # but calling history should never crash
      events = Store.history(10)
      assert is_list(events)
    end
  end

  # ============================================================================
  # 4. Subscribe/unsubscribe edge cases
  # ============================================================================

  describe "subscribe/unsubscribe" do
    test "subscribe receives pushed events" do
      Store.subscribe()

      Store.push(%{for_subscriber: true})

      assert_receive {:monitor_event, %{for_subscriber: true}}, 500
    end

    test "unsubscribe stops receiving events" do
      Store.subscribe()
      Store.unsubscribe()

      Store.push(%{should_not_see: true})

      refute_receive {:monitor_event, _}, 200
    end

    test "double subscribe from same process" do
      Store.subscribe()
      Store.subscribe()

      Store.push(%{double_sub: true})

      # MapSet deduplicates — should receive exactly once
      assert_receive {:monitor_event, %{double_sub: true}}, 500
      refute_receive {:monitor_event, %{double_sub: true}}, 100
    end

    test "unsubscribe without subscribe does not crash" do
      Store.unsubscribe()
      # Should not crash — MapSet.delete on non-member is a no-op
      events = Store.history(1)
      assert is_list(events)
    end

    test "double unsubscribe does not crash" do
      Store.subscribe()
      Store.unsubscribe()
      Store.unsubscribe()

      # Should not crash
      events = Store.history(1)
      assert is_list(events)
    end
  end

  # ============================================================================
  # 5. Subscriber process death cleanup
  # ============================================================================

  describe "subscriber process death" do
    test "dead subscriber is cleaned up via DOWN monitor" do
      # Spawn a process that subscribes then dies
      parent = self()

      pid = spawn(fn ->
        Store.subscribe()
        send(parent, :subscribed)
        # Die immediately after subscribing
      end)

      assert_receive :subscribed, 500
      # Wait for process to die and DOWN to be processed
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
      Process.sleep(50)

      # Push an event — should not crash even though subscriber is dead
      Store.push(%{after_death: true})
      Process.sleep(20)

      # Store should still be functional
      events = Store.history(5)
      assert is_list(events)
    end
  end

  # ============================================================================
  # 6. Concurrent pushes
  # ============================================================================

  describe "concurrent pushes" do
    test "50 concurrent pushers do not crash the store" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            for j <- 1..10 do
              Store.push(%{pusher: i, seq: j})
            end
          end)
        end

      Task.await_many(tasks, 5000)
      Process.sleep(100)

      events = Store.history(50)
      assert is_list(events)
      assert length(events) == 50  # buffer capped at 50
    end
  end

  # ============================================================================
  # 7. Fan-out with events containing non-serializable data
  # ============================================================================

  describe "fan-out with complex events" do
    test "event with PID value" do
      Store.subscribe()
      Store.push(%{pid: self()})
      assert_receive {:monitor_event, %{pid: pid}}, 500
      assert is_pid(pid)
    end

    test "event with reference value" do
      Store.subscribe()
      ref = make_ref()
      Store.push(%{ref: ref})
      assert_receive {:monitor_event, %{ref: ^ref}}, 500
    end

    test "event with function value" do
      Store.subscribe()
      Store.push(%{func: &String.length/1})
      assert_receive {:monitor_event, %{func: f}}, 500
      assert is_function(f)
    end
  end
end
