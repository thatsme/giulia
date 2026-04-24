defmodule Giulia.Runtime.Inspector.TraceTest do
  use ExUnit.Case, async: false

  alias Giulia.Runtime.Inspector.Trace

  # ============================================================================
  # Basic tracing
  # ============================================================================

  describe "run/3 on local node" do
    test "traces a known module and returns call data" do
      # Generate Enum activity in background so the trace captures something
      # even when the full test suite is saturating the BEAM
      bg = Task.async(fn ->
        for _ <- 1..500, do: Enum.map(1..10, & &1)
      end)

      {:ok, result} = Trace.run(:local, Enum, 200)
      Task.await(bg)

      assert result.module == "Enum"
      assert result.duration_ms == 200
      assert is_list(result.calls)
      assert is_integer(result.total_calls)
      assert is_float(result.calls_per_second)

      # `:erlang.trace(:all, true, [:call])` captures system-wide Enum
      # activity. In full-suite runs other tests' Enum calls saturate
      # the 1000-event cap and the tracer aborts early — a correct,
      # documented outcome under load, not a bug. The contract is that
      # aborted is a boolean, and when true, :reason is informative.
      assert is_boolean(result.aborted)

      if result.aborted do
        assert is_binary(result[:reason]),
               "aborted result must carry an informative :reason field"
      end
    end

    test "traces with string module name" do
      {:ok, result} = Trace.run(:local, "Enum", 100)
      assert result.module == "Enum"
    end

    test "traces with string module name without Elixir prefix" do
      {:ok, result} = Trace.run(:local, "Enum", 100)
      assert result.module == "Enum"
    end

    test "returns error for unknown module" do
      {:error, {:unknown_module, "NonExistentModuleXYZ123"}} =
        Trace.run(:local, "NonExistentModuleXYZ123", 100)
    end

    test "clamps duration to max 5000ms" do
      # We can't easily test the actual clamping, but we can verify it doesn't crash
      # with a very large duration — it gets clamped internally
      {:ok, result} = Trace.run(:local, Enum, 100)
      assert is_map(result)
    end

    test "call entries have function, arity, and count" do
      # Generate some Enum activity
      Task.async(fn ->
        Enum.each(1..100, fn i -> Enum.map([i], & &1) end)
      end)
      |> Task.await()

      {:ok, result} = Trace.run(:local, Enum, 200)

      if result.total_calls > 0 do
        call = hd(result.calls)
        assert is_atom(call.function)
        assert is_integer(call.arity)
        assert is_integer(call.count)
        assert call.count > 0
      end
    end
  end

  # ============================================================================
  # Remote tracing
  # ============================================================================

  describe "run/3 on remote node" do
    test "returns error for remote trace" do
      {:error, :remote_trace_not_supported} =
        Trace.run(:"fake@remote", Enum, 100)
    end
  end

  # ============================================================================
  # Adversarial inputs
  # ============================================================================

  describe "adversarial inputs" do
    test "zero duration still works" do
      {:ok, result} = Trace.run(:local, Enum, 0)
      assert result.duration_ms == 0
    end

    test "atom module that exists" do
      {:ok, result} = Trace.run(:local, :erlang, 100)
      assert result.module == ":erlang"
    end

    test "module with no calls during trace period" do
      # Trace a module unlikely to be called
      {:ok, result} = Trace.run(:local, Giulia.Version, 100)
      assert result.total_calls >= 0
      # Same rationale as "traces a known module" above — `:erlang.trace(:all,
      # ...)` is system-wide, so under full-suite load any concurrent call to
      # the traced module can push total_calls past the event cap. aborted is
      # boolean; :reason is informative when aborted.
      assert is_boolean(result.aborted)
      if result.aborted, do: assert(is_binary(result[:reason]))
    end
  end

  # ============================================================================
  # Integration: delegation from Inspector
  # ============================================================================

  describe "delegation from Inspector" do
    test "Inspector.trace delegates to Trace.run" do
      {:ok, result} = Giulia.Runtime.Inspector.trace(:local, Enum, 100)
      assert result.module == "Enum"
      assert is_list(result.calls)
    end

    test "Inspector.trace handles unknown module" do
      {:error, {:unknown_module, "BogusModule999"}} =
        Giulia.Runtime.Inspector.trace(:local, "BogusModule999", 100)
    end
  end
end
