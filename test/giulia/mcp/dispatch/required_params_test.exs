defmodule Giulia.MCP.Dispatch.RequiredParamsTest do
  @moduledoc """
  Filter-accountability suite covering required-parameter validation
  across every `Giulia.MCP.Dispatch.<Category>` module.

  These tests deliberately call dispatch handlers with empty / partial
  argument maps and assert the exact error tuple format the MCP server
  lifts to a protocol error. Two failure modes this catches:

    * Drop-side: a refactor adds a new required param but forgets to
      check it — handler silently calls business logic with `nil`.
    * Identity-side: error message text changes accidentally — MCP
      clients matching on the message string break silently.

  Adversarial-success cases that need a real project (cold-rescan,
  CubDB-backed lookups) are out of scope here — covered in the
  Tier 3 round-trip integration test.
  """

  use ExUnit.Case, async: true

  alias Giulia.MCP.Dispatch

  describe "Approval — required params" do
    test "respond errors when approval_id missing" do
      assert {:error, "Missing required parameter: approval_id"} =
               Dispatch.Approval.respond(%{})
    end

    test "get_pending errors when approval_id missing" do
      assert {:error, "Missing required parameter: approval_id"} =
               Dispatch.Approval.get_pending(%{})
    end
  end

  describe "Search — required params" do
    test "text errors when pattern missing" do
      assert {:error, "Missing required parameter: pattern"} = Dispatch.Search.text(%{})
    end

    test "semantic errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Search.semantic(%{})
    end

    test "semantic errors when concept missing (path present)" do
      assert {:error, "Missing required parameter: concept"} =
               Dispatch.Search.semantic(%{"path" => "/projects/example"})
    end

    test "semantic_status errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Search.semantic_status(%{})
    end
  end

  describe "Transaction — required params" do
    test "enable errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Transaction.enable(%{})
    end

    test "rollback errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Transaction.rollback(%{})
    end

    test "staged with no path returns transaction_mode: false" do
      # Documented soft contract: staged is the only Transaction handler
      # that accepts an absent path — returns a no-op preview rather than
      # erroring.
      assert {:ok, %{transaction_mode: false, staged_files: []}} =
               Dispatch.Transaction.staged(%{})
    end
  end

  describe "Index — required params" do
    test "modules errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.modules(%{})
    end

    test "functions errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.functions(%{})
    end

    test "module_details errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.module_details(%{})
    end

    test "module_details errors when module missing (path present)" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Index.module_details(%{"path" => "/projects/example"})
    end

    test "summary errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.summary(%{})
    end

    test "scan errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.scan(%{})
    end

    test "verify errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.verify(%{})
    end

    test "compact errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.compact(%{})
    end

    test "complexity errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Index.complexity(%{})
    end

    test "enrichment errors when tool missing" do
      assert {:error, "Missing required parameter: tool"} = Dispatch.Index.enrichment(%{})
    end

    test "enrichment errors when project missing" do
      assert {:error, "Missing required parameter: project"} =
               Dispatch.Index.enrichment(%{"tool" => "credo"})
    end

    test "enrichment errors when payload_path missing" do
      assert {:error, "Missing required parameter: payload_path"} =
               Dispatch.Index.enrichment(%{"tool" => "credo", "project" => "/projects/example"})
    end

    test "enrichment validates non-existent project directory" do
      # Delegates to `Enrichment.Ingest.run_with_validation/3` which returns
      # `{:error, {:invalid_project, _}}` for any project string that doesn't
      # resolve to an existing directory; the dispatch shim formats that
      # tuple as a human-readable error string for MCP clients.
      assert {:error, "Missing or invalid :project" <> _} =
               Dispatch.Index.enrichment(%{
                 "tool" => "credo",
                 "project" => "/nonexistent/path/xyz",
                 "payload_path" => "/tmp/foo.json"
               })
    end
  end

  describe "Intelligence — required params" do
    test "briefing errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Intelligence.briefing(%{})
    end

    test "briefing errors when prompt and q both missing" do
      assert {:error, "Missing required parameter: prompt (or q)"} =
               Dispatch.Intelligence.briefing(%{"path" => "/projects/example"})
    end

    test "briefing_preflight errors when path missing" do
      assert {:error, "Missing required parameter: path"} =
               Dispatch.Intelligence.briefing_preflight(%{})
    end

    test "briefing_preflight errors when prompt missing (path present)" do
      assert {:error, "Missing required parameter: prompt"} =
               Dispatch.Intelligence.briefing_preflight(%{"path" => "/projects/example"})
    end

    test "brief_architect errors when path missing" do
      assert {:error, "Missing required parameter: path"} =
               Dispatch.Intelligence.brief_architect(%{})
    end

    test "plan_validate errors when path missing" do
      assert {:error, "Missing required parameter: path"} =
               Dispatch.Intelligence.plan_validate(%{})
    end

    test "plan_validate errors when plan missing (path present)" do
      assert {:error, "Missing required parameter: plan"} =
               Dispatch.Intelligence.plan_validate(%{"path" => "/projects/example"})
    end

    test "enrichments errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Intelligence.enrichments(%{})
    end

    test "enrichments errors when neither mfa nor module given" do
      assert {:error, "Provide either :mfa or :module parameter"} =
               Dispatch.Intelligence.enrichments(%{"path" => "/projects/example"})
    end
  end

  describe "Runtime — required params" do
    test "trace errors when module missing" do
      assert {:error, "Missing required parameter: module"} = Dispatch.Runtime.trace(%{})
    end

    test "connect errors when node missing" do
      assert {:error, "Missing required parameter: node"} = Dispatch.Runtime.connect(%{})
    end

    test "connect errors with descriptive message when node syntactically invalid" do
      # The Daemon.Helpers.safe_to_node_atom contract: bad shapes get a
      # human-readable error, not a crash. Surfacing through this dispatch
      # keeps MCP clients from seeing :badarg.
      assert {:error, "Invalid node name:" <> _} = Dispatch.Runtime.connect(%{"node" => "no-at"})
    end

    test "profile_by_id errors when id missing" do
      assert {:error, "Missing required parameter: id"} = Dispatch.Runtime.profile_by_id(%{})
    end

    test "observation_by_session_id errors when session_id missing" do
      assert {:error, "Missing required parameter: session_id"} =
               Dispatch.Runtime.observation_by_session_id(%{})
    end

    test "profile_latest surfaces the no-profile path with a friendly message" do
      # Pins the fix for the preexisting atom-mismatch bug — the
      # original code matched `{:error, :no_profiles}` but Monitor
      # returns `{:error, :not_found}`. Without seeding a profile, the
      # Monitor.Store should yield :not_found, which the dispatcher
      # must lift to the documented "No profiles available" string.
      assert {:error, "No profiles available"} = Dispatch.Runtime.profile_latest(%{})
    end
  end

  describe "Discovery — required params" do
    test "search errors when q missing" do
      assert {:error, "Missing required parameter: q"} = Dispatch.Discovery.search(%{})
    end
  end

  describe "Knowledge — required-path handlers" do
    # Twelve handlers all error identically on missing path. Listed
    # explicitly rather than looped — the test names show up in failure
    # output and let bisects catch which family broke.
    @path_only [
      :stats,
      :integrity,
      :dead_code,
      :cycles,
      :god_modules,
      :orphan_specs,
      :fan_in_out,
      :coupling,
      :api_surface,
      :change_risk,
      :heatmap,
      :unprotected_hubs,
      :struct_lifecycle,
      :duplicates,
      :audit,
      :topology,
      :conventions
    ]

    for fn_name <- @path_only do
      @tag fn_name: fn_name
      test "#{fn_name} errors when path missing", %{fn_name: fn_name} do
        assert {:error, "Missing required parameter: path"} =
                 apply(Dispatch.Knowledge, fn_name, [%{}])
      end
    end
  end

  describe "Knowledge — multi-param handlers" do
    test "dependents errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Knowledge.dependents(%{})
    end

    test "dependents errors when module missing" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Knowledge.dependents(%{"path" => "/projects/example"})
    end

    test "dependencies errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Knowledge.dependencies(%{})
    end

    test "dependencies errors when module missing" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Knowledge.dependencies(%{"path" => "/projects/example"})
    end

    test "centrality errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Knowledge.centrality(%{})
    end

    test "centrality errors when module missing" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Knowledge.centrality(%{"path" => "/projects/example"})
    end

    test "impact errors when module missing" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Knowledge.impact(%{"path" => "/projects/example"})
    end

    test "path errors when from missing" do
      assert {:error, "Missing required parameter: from"} =
               Dispatch.Knowledge.path(%{"path" => "/projects/example"})
    end

    test "path errors when to missing (from present)" do
      assert {:error, "Missing required parameter: to"} =
               Dispatch.Knowledge.path(%{"path" => "/projects/example", "from" => "Mod.A"})
    end

    test "logic_flow errors when from missing" do
      assert {:error, "Missing required parameter: from"} =
               Dispatch.Knowledge.logic_flow(%{"path" => "/projects/example"})
    end

    test "logic_flow errors when to missing (from present)" do
      assert {:error, "Missing required parameter: to"} =
               Dispatch.Knowledge.logic_flow(%{
                 "path" => "/projects/example",
                 "from" => "Mod.A.fn/0"
               })
    end

    test "style_oracle errors when q missing (path present)" do
      assert {:error, "Missing required parameter: q"} =
               Dispatch.Knowledge.style_oracle(%{"path" => "/projects/example"})
    end

    test "pre_impact_check errors when module missing" do
      assert {:error, "Missing required parameter: module"} =
               Dispatch.Knowledge.pre_impact_check(%{"path" => "/projects/example"})
    end

    test "pre_impact_check errors when action missing (module present)" do
      assert {:error, "Missing required parameter: action"} =
               Dispatch.Knowledge.pre_impact_check(%{
                 "path" => "/projects/example",
                 "module" => "Mod.A"
               })
    end

    test "verify_l2 errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Knowledge.verify_l2(%{})
    end

    test "verify_l3 errors when path missing" do
      assert {:error, "Missing required parameter: path"} = Dispatch.Knowledge.verify_l3(%{})
    end
  end
end
