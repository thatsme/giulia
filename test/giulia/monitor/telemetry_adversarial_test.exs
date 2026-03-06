defmodule Giulia.Monitor.TelemetryAdversarialTest do
  @moduledoc """
  Adversarial tests for Monitor.Telemetry handlers and serialization.

  Targets:
  - handle_inference_event with nil/empty/non-standard metadata
  - handle_http_event with malformed conn
  - extract_response_body with iodata, nil, non-binary
  - serialize_event with non-standard event shapes
  - safe_encode with PIDs, refs, tuples, functions, nested structures
  - truncate edge cases
  """
  use ExUnit.Case, async: false

  alias Giulia.Monitor.Store
  alias Giulia.Monitor.Telemetry

  # ============================================================================
  # 1. handle_inference_event adversarial
  # ============================================================================

  describe "handle_inference_event" do
    test "nil measurements and metadata" do
      # Should not crash — just pushes whatever it gets
      Telemetry.handle_inference_event(
        [:giulia, :inference, :start],
        nil,
        nil,
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: "giulia.inference.start"} -> true
        _ -> false
      end)
    end

    test "empty event name list" do
      Telemetry.handle_inference_event([], %{}, %{}, nil)
      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: ""} -> true
        _ -> false
      end)
    end

    test "measurements with non-numeric values" do
      Telemetry.handle_inference_event(
        [:giulia, :test, :event],
        %{duration: "not_a_number", count: nil},
        %{tool: "read_file"},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: "giulia.test.event"} -> true
        _ -> false
      end)
    end

    test "metadata with PID and reference values" do
      Telemetry.handle_inference_event(
        [:giulia, :llm, :call],
        %{},
        %{pid: self(), ref: make_ref()},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: "giulia.llm.call"} -> true
        _ -> false
      end)
    end

    test "very long event name" do
      long_event = Enum.map(1..100, fn i -> :"segment_#{i}" end)
      Telemetry.handle_inference_event(long_event, %{}, %{}, nil)
      Process.sleep(20)

      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: ev} when is_binary(ev) -> String.contains?(ev, "segment_")
        _ -> false
      end)
    end
  end

  # ============================================================================
  # 2. handle_http_event adversarial
  # ============================================================================

  describe "handle_http_event" do
    test "http.start is a no-op" do
      result = Telemetry.handle_http_event([:giulia, :http, :start], %{}, %{}, nil)
      assert result == :ok
    end

    test "unknown event name is a no-op" do
      result = Telemetry.handle_http_event([:giulia, :http, :unknown], %{}, %{}, nil)
      assert result == :ok
    end

    test "http.stop with minimal conn-like map" do
      conn = %{
        method: "GET",
        request_path: "/api/test",
        query_string: "",
        status: 200,
        resp_body: "ok"
      }

      Telemetry.handle_http_event(
        [:giulia, :http, :stop],
        %{duration: 1_000_000},
        %{conn: conn},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{event: "giulia.http.stop", metadata: %{path: "/api/test"}} -> true
        _ -> false
      end)
    end

    test "http.stop with nil resp_body" do
      conn = %{
        method: "GET",
        request_path: "/api/nil_body",
        query_string: "",
        status: 200,
        resp_body: nil
      }

      Telemetry.handle_http_event(
        [:giulia, :http, :stop],
        %{duration: 500_000},
        %{conn: conn},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{metadata: %{resp_body: nil, path: "/api/nil_body"}} -> true
        _ -> false
      end)
    end

    test "http.stop with iodata list resp_body" do
      conn = %{
        method: "POST",
        request_path: "/api/iodata",
        query_string: "",
        status: 201,
        resp_body: ["hello", " ", "world"]
      }

      Telemetry.handle_http_event(
        [:giulia, :http, :stop],
        %{duration: 100_000},
        %{conn: conn},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      assert Enum.any?(events, fn
        %{metadata: %{resp_body: "hello world"}} -> true
        _ -> false
      end)
    end

    test "http.stop with very large resp_body gets truncated" do
      big_body = String.duplicate("x", 10_000)
      conn = %{
        method: "GET",
        request_path: "/api/big",
        query_string: "",
        status: 200,
        resp_body: big_body
      }

      Telemetry.handle_http_event(
        [:giulia, :http, :stop],
        %{duration: 100_000},
        %{conn: conn},
        nil
      )

      Process.sleep(20)
      events = Store.history(5)
      truncated_event = Enum.find(events, fn
        %{metadata: %{path: "/api/big"}} -> true
        _ -> false
      end)

      assert truncated_event != nil
      body = truncated_event.metadata.resp_body
      # Should be truncated to ~5000 + "[truncated]"
      assert byte_size(body) < 10_000
      assert body =~ "truncated"
    end

    test "http.stop with missing conn in metadata does not crash" do
      # Missing :conn key — handle_http_event pattern won't match,
      # falls through to catch-all
      result = Telemetry.handle_http_event(
        [:giulia, :http, :stop],
        %{duration: 100},
        %{},
        nil
      )
      assert result == :ok
    end
  end

  # ============================================================================
  # 3. Serialization adversarial (via Monitor router's safe_encode)
  # ============================================================================

  describe "serialization via history endpoint" do
    test "event with PID in metadata survives history round-trip" do
      Store.push(%{
        event: "test.pid",
        measurements: %{},
        metadata: %{pid: self()},
        timestamp: DateTime.utc_now()
      })

      Process.sleep(20)
      events = Store.history(5)
      # PIDs are in buffer as-is (serialization happens in router, not store)
      pid_event = Enum.find(events, fn
        %{event: "test.pid"} -> true
        _ -> false
      end)
      assert pid_event != nil
      assert is_pid(pid_event.metadata.pid)
    end

    test "event with deeply nested map" do
      deep = Enum.reduce(1..20, %{leaf: true}, fn i, acc -> %{"level_#{i}" => acc} end)
      Store.push(%{
        event: "test.deep",
        measurements: %{},
        metadata: deep,
        timestamp: DateTime.utc_now()
      })

      Process.sleep(20)
      events = Store.history(5)
      deep_event = Enum.find(events, fn
        %{event: "test.deep"} -> true
        _ -> false
      end)
      assert deep_event != nil
    end

    test "event with atom keys and values" do
      Store.push(%{
        event: "test.atoms",
        measurements: %{type: :counter},
        metadata: %{status: :ok, level: :info},
        timestamp: DateTime.utc_now()
      })

      Process.sleep(20)
      events = Store.history(5)
      atom_event = Enum.find(events, fn
        %{event: "test.atoms"} -> true
        _ -> false
      end)
      assert atom_event != nil
    end
  end
end
