defmodule Giulia.Knowledge.GoldenFixtureTest do
  @moduledoc """
  L0 extraction-fidelity golden: a hand-verified fixture project whose
  COMPLETE expected edge set is written down, asserted with exact-set
  equality (closed world). Presence-only tests cannot catch fabrication —
  this suite exists because a fabricated edge class (`X -> *.Application
  :references`, fixed in commit f515d2e) survived every presence test and
  every L1/L2/L3 parity check in the project.

  Two closed-world assertions partition the ENTIRE graph:
    * module golden — every edge whose two endpoints are both module-level
      vertices (no /arity suffix)
    * MFA golden — every remaining edge (function-level calls, behaviour /
      protocol / router dispatch, function-reference forms)
  Any edge the Builder emits that is not written here fails the suite as
  UNEXPECTED (fabrication); any golden edge it stops emitting fails as
  MISSING (under-extraction).

  ## Honest boundary — what green here does and does not mean

  This is a REGRESSION SENSOR OVER ENUMERATED SEMANTICS, not proof of
  general extraction fidelity. It pins exactly the constructs the fixture
  contains — one per Builder pass — plus the one known fabrication class.
  A passing golden means "the extractor still agrees with a human on this
  subset"; it says nothing about arbitrary input. Do not read green here
  the way green verify_l2 was once misread. The un-enumerated space is
  phase 2 (resolver contracts, runtime-witness differential).

  Not exercised (deliberately, documented): Pass 3 xref edges (fixtures
  are never compiled — zero xref-class edges by design), Pass 11
  use-injected imports, `:erlang_atom` / `:mfa_arg_ref` call forms,
  vertex-set assertions (edges are the fidelity surface).

  ## Updating the goldens

  On failure, the message prints missing and unexpected separately
  (under-extraction vs fabrication read differently at a glance) and the
  full actual set in copy-pasteable golden format. A legitimate new pass
  is a reviewed diff of that block — never loosen exact-set to subset.
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Builder

  @fixture_dir Path.expand("../../fixtures/golden", __DIR__)

  setup_all do
    ast_data =
      @fixture_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.sort()
      |> Map.new(fn file ->
        path = Path.join(@fixture_dir, file)
        {:ok, data} = Giulia.AST.Processor.analyze_file(path)
        {path, data}
      end)

    # Full multi-pass Builder pipeline — the same entry point a real scan
    # uses (Knowledge.Store rebuild -> Builder.build_graph on all ASTs).
    # All fixture vertices are present simultaneously, so the whole-graph
    # synthesis passes (6-10) have real targets to dispatch against.
    {:ok, graph: Builder.build_graph(ast_data)}
  end

  # Every module<->module edge the Builder must emit for the fixture —
  # exactly these, no more, no fewer. Pass ownership per edge in comments;
  # see the fixture files for the per-construct reasoning.
  @module_golden MapSet.new([
                   # Pass 6 — supervision children list
                   {"Golden.Application", "Golden.Server", :references},
                   # Pass 12 — same pair, distinct label. Pass 6 sees only that
                   # the alias appears in the file; Pass 12 carries the child's
                   # order, restart and conditionality. Both edges are correct
                   # and independent — Pass 12 adds, it never rewrites Pass 6.
                   {"Golden.Application", "Golden.Server",
                    {:supervises,
                     %{restart: :unknown, order: 0, strategy: "one_for_one", conditional: false}}},
                   # Pass 2 — explicit alias
                   {"Golden.Consumer", "Golden.Util", :depends_on},
                   # defdelegate pass — single-pair and multi-pair (as:) opts.
                   # History: degraded to :references until the Sourceror
                   # keyword-shape fix (this suite's maiden-run catch).
                   {"Golden.Facade", "Golden.Util", :depends_on},
                   {"Golden.Facade", "Golden.Data", :depends_on},
                   # Pass 6 — MFA-form aliases land AFTER promotion, so :references
                   {"Golden.Jobs", "Golden.Util", :references},
                   # Pass 2 — require emits both labels (pinned as-is)
                   {"Golden.MacroUser", "Golden.Util", :depends_on},
                   {"Golden.MacroUser", "Golden.Util", :implements},
                   # Pass 6 — real full-name reference to the project's *.Application
                   {"Golden.Release", "Golden.Application", :references},
                   # Pass 6 — controller alias in route args
                   {"Golden.Router", "Golden.HealthController", :references},
                   # Pass 5 — promoted from the :direct MFA call
                   {"Golden.Server", "Golden.Util", {:calls, :promoted}},
                   # Pass 6 — defimpl head aliases
                   {"Golden.Proto.Golden.Data", "Golden.Data", :references},
                   {"Golden.Proto.Golden.Data", "Golden.Proto", :references}
                 ])

  # Every edge touching a function-level vertex — dispatch synthesis and
  # call/reference resolution classes.
  @mfa_golden MapSet.new([
                # Pass 8 — behaviour dispatch (use Application / use GenServer)
                {"Application", "Golden.Application.start/2", {:calls, :behaviour_impl}},
                {"GenServer", "Golden.Server.init/1", {:calls, :behaviour_impl}},
                {"GenServer", "Golden.Server.handle_call/3", {:calls, :behaviour_impl}},
                # Pass 7 — protocol dispatch
                {"Golden.Proto", "Golden.Proto.Golden.Data.render/1", {:calls, :protocol_impl}},
                # Pass 9 — router dispatch (bare DSL, no Phoenix)
                {"Golden.Router", "Golden.HealthController.check/2", {:calls, :router_dispatch}},
                # Pass 4 — resolution classes
                {"Golden.Server.handle_call/3", "Golden.Util.normalize/1", {:calls, :direct}},
                {"Golden.Consumer.run/1", "Golden.Util.normalize/1", {:calls, :alias_resolved}},
                {"Golden.Util.normalize/1", "Golden.Util.scrub/1", {:calls, :local}},
                # Pass 10 — function-reference forms
                {"Golden.Jobs.spec/0", "Golden.Util.normalize/1", {:calls, :mfa_ref}},
                {"Golden.Jobs.hook/0", "Golden.Util.normalize/1", {:calls, :capture_ref}},
                {"Golden.Jobs.kick/0", "Golden.Util.normalize/1", {:calls, :apply_ref}}
              ])

  describe "closed-world golden" do
    test "module-level edge set matches exactly", %{graph: graph} do
      assert_exact(actual_edges(graph, :module), @module_golden, "module-level")
    end

    test "function-level edge set matches exactly", %{graph: graph} do
      assert_exact(actual_edges(graph, :mfa), @mfa_golden, "function-level")
    end
  end

  describe "the pinned fabrication class (commit f515d2e)" do
    # Invariant: bare stdlib aliases (Application.get_env, Version.parse)
    # in a project that contains *.Application must fabricate NOTHING.
    # This is the regression test this bug class should always have had.
    test "bare Application.get_env fabricates zero edges to Golden.Application",
         %{graph: graph} do
      assert Graph.out_edges(graph, "Golden.Config") == [],
             "Golden.Config must have zero outgoing edges; " <>
               "got: #{inspect(Enum.map(Graph.out_edges(graph, "Golden.Config"), &{&1.v1, &1.v2, &1.label}))}"
    end

    # Invariant: the only module-level inbound edge on Golden.Application
    # is the legitimate full-name reference from Golden.Release.
    test "Golden.Application inbound = the one real reference", %{graph: graph} do
      inbound =
        graph
        |> Graph.in_edges("Golden.Application")
        |> Enum.map(fn e -> {e.v1, e.label} end)
        |> Enum.sort()

      assert inbound == [{"Golden.Release", :references}]
    end
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  # Partition rule: module vertices carry no /arity suffix. An edge with
  # BOTH endpoints suffix-free is module-level; everything else is MFA.
  defp actual_edges(graph, kind) do
    graph
    |> Graph.edges()
    |> Enum.map(fn e -> {e.v1, e.v2, e.label} end)
    |> Enum.filter(fn {v1, v2, _label} ->
      case kind do
        :module -> not mfa_vertex?(v1) and not mfa_vertex?(v2)
        :mfa -> mfa_vertex?(v1) or mfa_vertex?(v2)
      end
    end)
    |> MapSet.new()
  end

  defp mfa_vertex?(name), do: is_binary(name) and String.contains?(name, "/")

  defp assert_exact(actual, expected, label) do
    missing = MapSet.difference(expected, actual)
    unexpected = MapSet.difference(actual, expected)

    assert MapSet.equal?(actual, expected), """
    #{label} golden mismatch.

    MISSING — in the golden but not emitted (under-extraction):
    #{format_edges(missing)}
    UNEXPECTED — emitted but not in the golden (fabrication):
    #{format_edges(unexpected)}
    Full actual set in golden format (for a REVIEWED update, never a blind paste):
    #{format_edges(actual)}
    """
  end

  defp format_edges(edges) do
    if Enum.empty?(edges) do
      "  (none)\n"
    else
      edges
      |> Enum.sort()
      |> Enum.map_join("", fn {v1, v2, label} ->
        "  {#{inspect(v1)}, #{inspect(v2)}, #{inspect(label)}},\n"
      end)
    end
  end
end
