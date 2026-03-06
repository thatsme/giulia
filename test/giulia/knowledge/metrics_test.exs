defmodule Giulia.Knowledge.MetricsTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Metrics

  describe "coupling_from_calls/1" do
    test "groups call triples into coupling pairs" do
      triples = [
        {"A", "B", "foo"},
        {"A", "B", "bar"},
        {"A", "C", "baz"},
        {"C", "A", "qux"}
      ]

      {:ok, %{pairs: pairs, count: count}} = Metrics.coupling_from_calls(triples)
      assert count == 3

      ab = Enum.find(pairs, fn p -> p.caller == "A" and p.callee == "B" end)
      assert ab.call_count == 2
      assert ab.distinct_functions == 2
      assert "foo" in ab.functions
      assert "bar" in ab.functions
    end

    test "returns empty for no calls" do
      {:ok, %{pairs: [], count: 0}} = Metrics.coupling_from_calls([])
    end

    test "sorts by call_count descending" do
      triples = [
        {"A", "B", "f1"},
        {"A", "C", "f2"},
        {"A", "C", "f3"},
        {"A", "C", "f4"}
      ]

      {:ok, %{pairs: [first | _]}} = Metrics.coupling_from_calls(triples)
      assert first.callee == "C"
      assert first.call_count == 3
    end

    test "limits to 50 pairs" do
      # Generate 60 distinct pairs
      triples = for i <- 1..60, do: {"Caller", "Callee#{i}", "func"}
      {:ok, %{count: count}} = Metrics.coupling_from_calls(triples)
      assert count == 50
    end
  end

  describe "build_coupling_map_from_calls/1" do
    test "returns max coupling per caller module" do
      triples = [
        {"A", "B", "foo"},
        {"A", "B", "bar"},
        {"A", "B", "baz"},
        {"A", "C", "qux"},
        {"D", "E", "one"}
      ]

      map = Metrics.build_coupling_map_from_calls(triples)
      # A calls B 3 times, C 1 time — max is 3
      assert map["A"] == 3
      assert map["D"] == 1
    end

    test "returns empty map for no calls" do
      assert Metrics.build_coupling_map_from_calls([]) == %{}
    end

    test "handles single call per module" do
      triples = [{"X", "Y", "hello"}]
      map = Metrics.build_coupling_map_from_calls(triples)
      assert map["X"] == 1
    end
  end
end
