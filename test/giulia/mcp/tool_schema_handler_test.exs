defmodule Giulia.MCP.ToolSchemaHandlerTest do
  @moduledoc """
  Filter-accountability tests for `ToolSchema.handler_for/1` — the
  table-driven dispatch lookup that replaces the per-prefix
  `defp dispatch_<cat>` clauses.

  Per `memory:feedback_integrity_pattern`, the four failure modes the
  resolver could exhibit:

    * Drop-side: a valid tool name resolves to `:no_handler`.
    * Identity-side: a tool name resolves to the wrong dispatch module.
    * Atom leak: a malicious tool name like `"runtime_$$$"` causes
      `String.to_atom/1` instead of `String.to_existing_atom/1`.
    * Function-existence bypass: an existing atom that is NOT an
      exported `/1` function on the dispatch module returns a stale
      MFA that crashes at invoke time.

  Each is exercised below.
  """

  use ExUnit.Case, async: true

  alias Giulia.MCP.{Dispatch, ToolSchema}

  describe "handler_for/1 — category prefix routing" do
    test "knowledge_stats → Dispatch.Knowledge.stats" do
      assert {Dispatch.Knowledge, :stats} = ToolSchema.handler_for("knowledge_stats")
    end

    test "knowledge_pre_impact_check → Dispatch.Knowledge.pre_impact_check" do
      assert {Dispatch.Knowledge, :pre_impact_check} =
               ToolSchema.handler_for("knowledge_pre_impact_check")
    end

    test "index_modules → Dispatch.Index.modules" do
      assert {Dispatch.Index, :modules} = ToolSchema.handler_for("index_modules")
    end

    test "search_text → Dispatch.Search.text" do
      assert {Dispatch.Search, :text} = ToolSchema.handler_for("search_text")
    end

    test "runtime_pulse → Dispatch.Runtime.pulse" do
      assert {Dispatch.Runtime, :pulse} = ToolSchema.handler_for("runtime_pulse")
    end

    test "transaction_enable → Dispatch.Transaction.enable" do
      assert {Dispatch.Transaction, :enable} = ToolSchema.handler_for("transaction_enable")
    end

    test "approval_respond → Dispatch.Approval.respond" do
      assert {Dispatch.Approval, :respond} = ToolSchema.handler_for("approval_respond")
    end

    test "monitor_history → Dispatch.Monitor.history" do
      assert {Dispatch.Monitor, :history} = ToolSchema.handler_for("monitor_history")
    end

    test "discovery_skills → Dispatch.Discovery.skills" do
      assert {Dispatch.Discovery, :skills} = ToolSchema.handler_for("discovery_skills")
    end

    test "intelligence_briefing → Dispatch.Intelligence.briefing" do
      assert {Dispatch.Intelligence, :briefing} = ToolSchema.handler_for("intelligence_briefing")
    end

    test "intelligence_report_rules → Dispatch.Intelligence.report_rules" do
      assert {Dispatch.Intelligence, :report_rules} =
               ToolSchema.handler_for("intelligence_report_rules")
    end
  end

  describe "handler_for/1 — special-prefix routing" do
    # These tool names come from endpoints under `/api/briefing/*`,
    # `/api/brief/*`, `/api/plan/*` — the resolver routes them to
    # Dispatch.Intelligence with the FULL tool name as the function
    # atom (not stripped after the prefix).
    test "briefing_preflight → Dispatch.Intelligence.briefing_preflight" do
      assert {Dispatch.Intelligence, :briefing_preflight} =
               ToolSchema.handler_for("briefing_preflight")
    end

    test "brief_architect → Dispatch.Intelligence.brief_architect" do
      assert {Dispatch.Intelligence, :brief_architect} =
               ToolSchema.handler_for("brief_architect")
    end

    test "plan_validate → Dispatch.Intelligence.plan_validate" do
      assert {Dispatch.Intelligence, :plan_validate} =
               ToolSchema.handler_for("plan_validate")
    end
  end

  describe "handler_for/1 — failure modes" do
    test "tool name with unknown category → :no_handler" do
      assert :no_handler = ToolSchema.handler_for("foo_bar")
    end

    test "tool name with known category but unknown function → :no_handler" do
      # `:nonexistent_function_atom_xyz` is unlikely to exist anywhere;
      # if it doesn't, the resolver hits the ArgumentError rescue and
      # returns :no_handler. If it does (e.g., another test or module
      # references it), the function_exported? check still rejects it.
      assert :no_handler = ToolSchema.handler_for("knowledge_nonexistent_function_atom_xyz")
    end

    test "atoms-from-strings is gated by String.to_existing_atom — random suffix → :no_handler" do
      # If the resolver naively used `String.to_atom/1` it would leak
      # a fresh atom into the global table on every call. This is a
      # real DoS vector — MCP clients are partially-untrusted.
      # A tool name with random bytes that no module ever defines as
      # an atom must return :no_handler without leaking.
      random_suffix = "rstuvwxyz_#{:erlang.unique_integer([:positive])}"
      assert :no_handler = ToolSchema.handler_for("knowledge_#{random_suffix}")
    end

    test "empty tool name → :no_handler" do
      assert :no_handler = ToolSchema.handler_for("")
    end

    test "tool name that is just the prefix (no sub-key) → :no_handler" do
      # `"knowledge_"` would split to module=Dispatch.Knowledge, fun_str="".
      # The empty-string atom doesn't correspond to any /1 function.
      assert :no_handler = ToolSchema.handler_for("knowledge_")
    end
  end

  describe "unhandled_tools/0" do
    test "no MCP-compatible tool is missing a dispatch handler" do
      # The Tier 3 contract: every `@skill` that survives the
      # `mcp_compatible?` filter MUST have a function in its matching
      # `Giulia.MCP.Dispatch.<Category>` module. New routes that ship
      # without a dispatcher will fail here — fix is to add the
      # function or mark the route MCP-incompatible (HTML/SSE/`/stream`).
      assert [] = ToolSchema.unhandled_tools()
    end

    test "returns a list of strings (defensive shape contract)" do
      gaps = ToolSchema.unhandled_tools()
      assert is_list(gaps)
      assert Enum.all?(gaps, &is_binary/1)
    end

    test "every resolvable tool name is invocable via an arity-1 function" do
      # Round-trip integrity: if handler_for returns a MFA, the function
      # MUST exist as /1 on the module. The resolver itself enforces
      # this via function_exported? — this test pins the contract.
      tools = ToolSchema.all_tools()

      bad =
        Enum.flat_map(tools, fn tool ->
          case ToolSchema.handler_for(tool.name) do
            {module, fun} ->
              if function_exported?(module, fun, 1), do: [], else: [{tool.name, module, fun}]

            :no_handler ->
              []
          end
        end)

      assert bad == [],
             "Resolver returned MFAs that are not function_exported?/3: #{inspect(bad)}"
    end
  end
end
