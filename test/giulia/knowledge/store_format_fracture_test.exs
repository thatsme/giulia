defmodule Giulia.Knowledge.StoreFormatFractureTest do
  @moduledoc """
  Pure-function coverage for `Knowledge.Store.format_fracture/1` — the
  single source of truth for behaviour-fracture serialization shared
  between `audit/1` (used by HTTP `/api/knowledge/audit` and MCP
  `knowledge_audit`) and `integrity_report/1` (HTTP `/api/knowledge/integrity`
  and MCP `knowledge_integrity`).

  Pre-lift, this logic lived in two places: `Daemon.Helpers.format_fracture/1`
  (HTTP) and a private copy in `Giulia.MCP.Dispatch.Knowledge` (MCP). The
  MCP copy was missing the `{name, arity}` → `"name/arity"` formatting
  step — clients of the MCP `knowledge_integrity` tool got tuples back,
  while HTTP clients got strings. This test pins the canonical shape.
  """

  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Store

  describe "format_fracture/1" do
    test "formats a full fracture map with name/arity strings" do
      fracture = %{
        implementer: "MyModule",
        missing: [{:foo, 2}, {:bar, 1}],
        injected: [{:baz, 0}],
        optional_omitted: [{:qux, 3}],
        heuristic_injected: []
      }

      result = Store.format_fracture(fracture)

      assert result.implementer == "MyModule"
      assert "foo/2" in result.missing
      assert "bar/1" in result.missing
      assert "baz/0" in result.injected
      assert "qux/3" in result.optional_omitted
      assert result.heuristic_injected == []
    end

    test "handles empty lists gracefully" do
      fracture = %{
        implementer: "Empty",
        missing: [],
        injected: [],
        optional_omitted: [],
        heuristic_injected: []
      }

      result = Store.format_fracture(fracture)
      assert result.missing == []
      assert result.injected == []
    end

    test "handles missing keys with empty-list defaults" do
      fracture = %{implementer: "Partial"}
      result = Store.format_fracture(fracture)
      assert result.implementer == "Partial"
      assert result.missing == []
      assert result.injected == []
      assert result.optional_omitted == []
      assert result.heuristic_injected == []
    end
  end
end
