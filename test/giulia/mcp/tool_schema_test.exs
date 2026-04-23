defmodule Giulia.MCP.ToolSchemaTest do
  @moduledoc """
  Filter-accountability tests for `ToolSchema.mcp_compatible?/1`.

  The MCP tool list is derived at boot from every router's @skill
  annotations. Skills that return HTML pages (dashboards), that push
  Server-Sent Events, or that live under an endpoint ending in
  `/stream` are filtered out because MCP clients expect structured
  JSON tool output, not streams or markup.

  Dual-assertion discipline:
    * Drop-side — each exclusion criterion (HTML returns, SSE returns,
      /stream endpoints) is asserted in isolation.
    * Pass-through — skills that should survive the filter must not be
      dropped by over-eager substring matching.
  """
  use ExUnit.Case, async: true

  alias Giulia.MCP.ToolSchema

  # Canonical shape of a skill entry — only :endpoint and :returns
  # participate in the filter, so other fields are stubbed.
  defp skill(overrides \\ %{}) do
    Map.merge(
      %{
        name: "stub",
        intent: "stub intent",
        endpoint: "GET /api/example",
        params: %{},
        returns: "JSON response",
        category: "example"
      },
      overrides
    )
  end

  describe "mcp_compatible?/1 — drop-side accountability" do
    test "drops skills returning HTML" do
      refute ToolSchema.mcp_compatible?(skill(%{returns: "HTML dashboard page"}))
    end

    test "drops skills returning Server-Sent Events" do
      refute ToolSchema.mcp_compatible?(
               skill(%{returns: "Server-Sent Events stream of telemetry data"})
             )
    end

    test "drops skills returning an SSE stream" do
      refute ToolSchema.mcp_compatible?(skill(%{returns: "SSE stream of events"}))
    end

    test "drops skills whose endpoint ends in /stream" do
      refute ToolSchema.mcp_compatible?(
               skill(%{endpoint: "GET /api/monitor/stream", returns: "JSON"})
             )
    end

    test "case-insensitive HTML match" do
      refute ToolSchema.mcp_compatible?(skill(%{returns: "html fragment"}))
      refute ToolSchema.mcp_compatible?(skill(%{returns: "Rendered HTML"}))
    end

    test "case-insensitive endpoint /stream match" do
      refute ToolSchema.mcp_compatible?(
               skill(%{endpoint: "get /api/monitor/STREAM", returns: "JSON"})
             )
    end
  end

  describe "mcp_compatible?/1 — pass-through accountability" do
    # Pass-through fixtures must survive the filter. Each represents a
    # class of skill that the MCP surface explicitly wants to expose.
    @pass_through_fixtures [
      %{endpoint: "GET /api/knowledge/stats", returns: "JSON graph statistics"},
      %{endpoint: "POST /api/transaction/commit", returns: "JSON commit result"},
      %{endpoint: "GET /api/index/modules", returns: "JSON list of modules"},
      %{
        endpoint: "GET /api/intelligence/briefing",
        returns: "JSON briefing with risk assessment"
      },
      %{endpoint: "POST /api/runtime/connect", returns: "JSON connection result"},
      # Returns text — not HTML/SSE — must survive
      %{endpoint: "GET /api/intelligence/report_rules", returns: "Markdown text of rules"},
      # Contains the substring "stream" in a non-/stream endpoint — must survive
      %{endpoint: "GET /api/runtime/stream_stats_summary", returns: "JSON summary"},
      # Returns JSON with "assessment" (which contains "sse" as substring) — regression
      # guard: the filter must use phrase matches, not naked substring checks
      %{endpoint: "GET /api/intelligence/validate", returns: "JSON validation with risk assessment"}
    ]
    for fixture <- @pass_through_fixtures do
      @tag fixture: fixture
      test "passes through #{inspect(Map.get(fixture, :endpoint))}", %{fixture: fixture} do
        assert ToolSchema.mcp_compatible?(skill(fixture)),
               "fixture should survive the MCP filter but was dropped: #{inspect(fixture)}"
      end
    end
  end

  describe "mcp_compatible?/1 — specific known cases from AlexClaw/Giulia" do
    # Real skill shapes from the production routers. Ground-truth
    # regression check for behavior we already verified manually.
    test "Monitor dashboard is filtered (HTML return)" do
      refute ToolSchema.mcp_compatible?(
               skill(%{endpoint: "GET /api/monitor", returns: "HTML dashboard page"})
             )
    end

    test "Monitor graph visualization is filtered (HTML return)" do
      refute ToolSchema.mcp_compatible?(
               skill(%{
                 endpoint: "GET /api/monitor/graph",
                 returns: "HTML graph visualization page"
               })
             )
    end

    test "Monitor stream is filtered (SSE return + /stream endpoint)" do
      refute ToolSchema.mcp_compatible?(
               skill(%{
                 endpoint: "GET /api/monitor/stream",
                 returns: "Server-Sent Events stream of telemetry data"
               })
             )
    end

    test "Monitor history is NOT filtered" do
      assert ToolSchema.mcp_compatible?(
               skill(%{
                 endpoint: "GET /api/monitor/history",
                 returns: "JSON list of recent events"
               })
             )
    end

    test "Intelligence validate is NOT filtered despite 'assessment' substring" do
      # The old filter implementation used naive substring checks.
      # 'risk assessment' contains 'sse' as a substring — verify the
      # current filter uses phrase matching ('sse stream') and lets
      # this through. See the earlier debugging session where this
      # nearly caused a false-positive drop.
      assert ToolSchema.mcp_compatible?(
               skill(%{
                 endpoint: "POST /api/intelligence/validate",
                 returns: "JSON validation result with risk assessment"
               })
             )
    end
  end
end
