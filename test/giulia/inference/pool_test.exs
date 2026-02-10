defmodule Giulia.Inference.PoolTest do
  @moduledoc """
  Tests for Inference.Pool — back-pressure pool for inference requests.

  Tests struct defaults, child_spec generation, and stat tracking.
  Does NOT start real pools (would need Registry + Orchestrator deps).
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.Pool

  # ============================================================================
  # Struct defaults
  # ============================================================================

  describe "struct defaults" do
    test "new struct has nil provider" do
      pool = %Pool{}
      assert pool.provider == nil
    end

    test "new struct is not busy" do
      pool = %Pool{}
      assert pool.busy == false
    end

    test "new struct has empty queue" do
      pool = %Pool{}
      assert :queue.len(pool.queue) == 0
    end

    test "new struct has zero stats" do
      pool = %Pool{}
      assert pool.stats.total_requests == 0
      assert pool.stats.completed == 0
      assert pool.stats.failed == 0
      assert pool.stats.timeouts == 0
    end

    test "current_request starts nil" do
      pool = %Pool{}
      assert pool.current_request == nil
    end
  end

  # ============================================================================
  # child_spec/1
  # ============================================================================

  describe "child_spec/1" do
    test "generates spec with unique id" do
      spec = Pool.child_spec(:local_3b)
      assert spec.id == {Pool, :local_3b}
      assert spec.type == :worker
      assert spec.restart == :permanent
    end

    test "different providers get different ids" do
      spec_3b = Pool.child_spec(:local_3b)
      spec_cloud = Pool.child_spec(:cloud_sonnet)
      assert spec_3b.id != spec_cloud.id
    end

    test "start tuple references start_link" do
      spec = Pool.child_spec(:cloud_sonnet)
      assert {Pool, :start_link, [:cloud_sonnet]} = spec.start
    end
  end

  # ============================================================================
  # Stats tracking (internal logic, tested via struct manipulation)
  # ============================================================================

  describe "stats tracking" do
    test "stats map has expected keys" do
      pool = %Pool{}
      assert Map.has_key?(pool.stats, :total_requests)
      assert Map.has_key?(pool.stats, :completed)
      assert Map.has_key?(pool.stats, :failed)
      assert Map.has_key?(pool.stats, :timeouts)
    end

    test "incrementing total_requests" do
      pool = %Pool{}
      updated = %{pool | stats: %{pool.stats | total_requests: pool.stats.total_requests + 1}}
      assert updated.stats.total_requests == 1
    end

    test "queue operations work correctly" do
      pool = %Pool{}
      queue = :queue.in({self(), make_ref(), "prompt", []}, pool.queue)
      assert :queue.len(queue) == 1

      {{:value, {_, _, prompt, _}}, queue2} = :queue.out(queue)
      assert prompt == "prompt"
      assert :queue.len(queue2) == 0
    end
  end

  # ============================================================================
  # Public API exports
  # ============================================================================

  describe "public API" do
    setup do
      Code.ensure_loaded!(Pool)
      :ok
    end

    test "exports infer/2 and infer/3" do
      assert function_exported?(Pool, :infer, 2)
      assert function_exported?(Pool, :infer, 3)
    end

    test "exports stats/1" do
      assert function_exported?(Pool, :stats, 1)
    end

    test "exports queue_length/1" do
      assert function_exported?(Pool, :queue_length, 1)
    end

    test "exports start_link/1" do
      assert function_exported?(Pool, :start_link, 1)
    end
  end
end
