defmodule Giulia.Intelligence.PlanValidator do
  @moduledoc """
  Plan Validation Gate — Graph-Aware Pre-flight for Code Changes.

  Pure functional module (no GenServer). Validates a proposed plan
  (list of modules to modify + actions) against the Knowledge Graph
  and returns a verdict before any code is written.

  Five validation checks:
  1. Cycle introduction — clone graph, add proposed edges, detect new cycles
  2. Red zone collision — count red-zone modules in the plan
  3. Hub risk aggregation — sum centrality degrees across touched modules
  4. Blast radius preview — union of downstream dependents
  5. Unprotected hub write — check if plan modifies unprotected hubs

  Verdicts: :approved, :warning, :rejected
  """

  alias Giulia.Knowledge.Store, as: KnowledgeStore
  alias Giulia.Knowledge.Analyzer

  require Logger

  @hub_degree_threshold 40
  @red_zone_warning_threshold 2

  @spec validate(map(), String.t(), keyword()) :: {:ok, map()}
  def validate(plan, project_path, _opts \\ []) do
    modules_touched = plan["modules_touched"] || []
    actions = plan["actions"] || []

    # Run all checks independently
    checks = [
      check_cycles(project_path, actions),
      check_red_zones(project_path, modules_touched),
      check_hub_risk(project_path, modules_touched),
      check_blast_radius(project_path, modules_touched),
      check_unprotected_writes(project_path, modules_touched)
    ]

    # Determine overall verdict
    verdict = compute_verdict(checks)
    risk_score = compute_risk_score(checks)
    recommendations = build_recommendations(checks, modules_touched, project_path)

    {:ok, %{
      verdict: verdict,
      risk_score: risk_score,
      modules_touched: modules_touched,
      checks: Enum.map(checks, &sanitize_check/1),
      recommendations: recommendations
    }}
  rescue
    e ->
      Logger.warning("PlanValidator: validation failed: #{Exception.message(e)}")
      {:ok, %{
        verdict: "error",
        risk_score: 0,
        modules_touched: plan["modules_touched"] || [],
        checks: [%{check: "validation_error", status: "error", detail: Exception.message(e)}],
        recommendations: ["Validation encountered an error — proceed with caution"]
      }}
  end

  # ============================================================================
  # Check 1: Cycle Introduction
  # ============================================================================

  defp check_cycles(project_path, actions) do
    graph = KnowledgeStore.graph(project_path)

    # Find "create" actions that introduce new module dependencies
    new_edges =
      actions
      |> Enum.filter(fn a -> a["type"] in ["create", "add_dependency"] end)
      |> Enum.flat_map(fn a ->
        deps = a["depends_on"] || []
        module = a["module"]
        Enum.map(deps, fn dep -> {module, dep} end)
      end)

    if new_edges == [] do
      %{check: "cycle_detection", status: "pass", detail: "No new dependencies proposed", risk: 0}
    else
      # Clone graph and add proposed edges
      test_graph =
        Enum.reduce(new_edges, graph, fn {from, to}, g ->
          g
          |> Graph.add_vertex(from, :module)
          |> Graph.add_vertex(to, :module)
          |> Graph.add_edge(from, to)
        end)

      # Detect cycles in the modified graph
      case Analyzer.cycles(test_graph) do
        {:ok, %{cycles: []}} ->
          %{check: "cycle_detection", status: "pass", detail: "No new cycles introduced", risk: 0}

        {:ok, %{cycles: cycles}} ->
          # Check if these cycles existed before
          existing_cycles =
            case Analyzer.cycles(graph) do
              {:ok, %{cycles: c}} -> c
              _ -> []
            end

          new_cycles = cycles -- existing_cycles

          if new_cycles == [] do
            %{check: "cycle_detection", status: "pass", detail: "No new cycles (existing cycles unchanged)", risk: 0}
          else
            %{check: "cycle_detection", status: "rejected",
              detail: "#{length(new_cycles)} new cycle(s) would be introduced",
              new_cycles: new_cycles, risk: 100}
          end

        _ ->
          %{check: "cycle_detection", status: "pass", detail: "Cycle analysis inconclusive", risk: 0}
      end
    end
  rescue
    _ -> %{check: "cycle_detection", status: "pass", detail: "Cycle check skipped (graph unavailable)", risk: 0}
  end

  # ============================================================================
  # Check 2: Red Zone Collision
  # ============================================================================

  defp check_red_zones(project_path, modules_touched) do
    heatmap_data =
      case KnowledgeStore.heatmap(project_path) do
        {:ok, %{modules: modules}} -> modules
        _ -> []
      end

    red_modules =
      heatmap_data
      |> Enum.filter(fn m -> (m[:zone] || m["zone"]) == "red" end)
      |> Enum.map(fn m -> m[:module] || m["module"] end)
      |> MapSet.new()

    collisions =
      modules_touched
      |> Enum.filter(&MapSet.member?(red_modules, &1))

    red_details =
      Enum.map(collisions, fn mod ->
        entry = Enum.find(heatmap_data, fn m -> (m[:module] || m["module"]) == mod end)
        %{module: mod, score: entry[:score] || entry["score"]}
      end)

    count = length(collisions)

    cond do
      count >= @red_zone_warning_threshold ->
        %{check: "red_zone_collision", status: "warning",
          detail: "#{count} red-zone modules: #{Enum.map_join(red_details, ", ", &"#{&1.module} (#{&1.score})")}",
          red_modules: red_details, risk: count * 20}

      count == 1 ->
        %{check: "red_zone_collision", status: "info",
          detail: "1 red-zone module: #{hd(red_details).module} (#{hd(red_details).score})",
          red_modules: red_details, risk: 10}

      true ->
        %{check: "red_zone_collision", status: "pass",
          detail: "No red-zone modules in plan", risk: 0}
    end
  rescue
    _ -> %{check: "red_zone_collision", status: "pass", detail: "Heatmap unavailable", risk: 0}
  end

  # ============================================================================
  # Check 3: Hub Risk Aggregation
  # ============================================================================

  defp check_hub_risk(project_path, modules_touched) do
    degrees =
      modules_touched
      |> Enum.map(fn mod ->
        case KnowledgeStore.centrality(project_path, mod) do
          {:ok, %{in_degree: ind, out_degree: outd}} -> %{module: mod, in_degree: ind, out_degree: outd, total: (ind || 0) + (outd || 0)}
          _ -> %{module: mod, in_degree: 0, out_degree: 0, total: 0}
        end
      end)

    total_degree = Enum.sum(Enum.map(degrees, & &1.total))

    if total_degree > @hub_degree_threshold do
      top_hubs = degrees |> Enum.sort_by(& &1.total, :desc) |> Enum.take(3)

      %{check: "hub_risk", status: "warning",
        detail: "Total degree: #{total_degree} (threshold: #{@hub_degree_threshold}). Top: #{Enum.map_join(top_hubs, ", ", &"#{&1.module}=#{&1.total}")}",
        total_degree: total_degree, modules: degrees, risk: min(div(total_degree, 2), 50)}
    else
      %{check: "hub_risk", status: "pass",
        detail: "Total degree: #{total_degree}", total_degree: total_degree, risk: 0}
    end
  rescue
    _ -> %{check: "hub_risk", status: "pass", detail: "Centrality data unavailable", risk: 0}
  end

  # ============================================================================
  # Check 4: Blast Radius Preview
  # ============================================================================

  defp check_blast_radius(project_path, modules_touched) do
    all_downstream =
      modules_touched
      |> Enum.flat_map(fn mod ->
        case KnowledgeStore.impact_map(project_path, mod, 2) do
          {:ok, %{downstream: ds}} ->
            Enum.map(ds, fn
              {v, _d} -> v
              %{module: m} -> m
              other -> other
            end)
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in modules_touched))

    count = length(all_downstream)

    %{check: "blast_radius", status: "info",
      detail: "#{count} downstream modules affected",
      downstream_count: count,
      downstream: Enum.take(all_downstream, 20),
      risk: 0}
  rescue
    _ -> %{check: "blast_radius", status: "info", detail: "Impact analysis unavailable", risk: 0}
  end

  # ============================================================================
  # Check 5: Unprotected Hub Write
  # ============================================================================

  defp check_unprotected_writes(project_path, modules_touched) do
    unprotected =
      case KnowledgeStore.find_unprotected_hubs(project_path) do
        {:ok, %{modules: mods}} -> mods
        _ -> []
      end

    unprotected_names =
      unprotected
      |> Enum.map(fn m -> m[:module] || m["module"] end)
      |> MapSet.new()

    collisions =
      modules_touched
      |> Enum.filter(&MapSet.member?(unprotected_names, &1))

    collision_details =
      Enum.map(collisions, fn mod ->
        entry = Enum.find(unprotected, fn m -> (m[:module] || m["module"]) == mod end)
        %{
          module: mod,
          spec_ratio: entry[:spec_ratio] || entry["spec_ratio"] || 0,
          in_degree: entry[:in_degree] || entry["in_degree"] || 0,
          severity: entry[:severity] || entry["severity"]
        }
      end)

    if collisions != [] do
      %{check: "unprotected_write", status: "warning",
        detail: "#{length(collisions)} unprotected hub(s) modified: #{Enum.map_join(collision_details, ", ", &"#{&1.module} (#{round(&1.spec_ratio * 100)}% specs, #{&1.in_degree} dependents)")}",
        modules: collision_details, risk: length(collisions) * 15}
    else
      %{check: "unprotected_write", status: "pass",
        detail: "No unprotected hubs in plan", risk: 0}
    end
  rescue
    _ -> %{check: "unprotected_write", status: "pass", detail: "Unprotected hub data unavailable", risk: 0}
  end

  # ============================================================================
  # Verdict & Scoring
  # ============================================================================

  defp compute_verdict(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      "rejected" in statuses -> "rejected"
      Enum.count(statuses, &(&1 == "warning")) >= 2 -> "warning"
      "warning" in statuses -> "warning"
      true -> "approved"
    end
  end

  defp compute_risk_score(checks) do
    checks
    |> Enum.map(&(&1[:risk] || 0))
    |> Enum.sum()
    |> min(100)
  end

  defp build_recommendations(checks, modules_touched, project_path) do
    recs = []

    # Unprotected hub recommendations
    recs =
      case Enum.find(checks, &(&1.check == "unprotected_write" && &1.status == "warning")) do
        %{modules: mods} ->
          Enum.reduce(mods, recs, fn m, acc ->
            ["Add @spec to #{m.module} before modifying (#{round(m.spec_ratio * 100)}% coverage, #{m.in_degree} dependents)" | acc]
          end)
        _ -> recs
      end

    # Red zone recommendations
    recs =
      case Enum.find(checks, &(&1.check == "red_zone_collision" && &1.status == "warning")) do
        %{red_modules: mods} when length(mods) >= 2 ->
          names = Enum.map_join(mods, " and ", & &1.module)
          ["Consider splitting the plan: modify #{names} in separate commits" | recs]
        _ -> recs
      end

    # Hub risk recommendations
    recs =
      case Enum.find(checks, &(&1.check == "hub_risk" && &1.status == "warning")) do
        %{total_degree: td} ->
          ["High hub density (degree #{td}): ensure thorough testing of all #{length(modules_touched)} modules" | recs]
        _ -> recs
      end

    # Runtime alert if available
    recs =
      if Giulia.Runtime.Collector.active?() do
        case Giulia.Runtime.Inspector.hot_spots(:local, project_path) do
          {:ok, spots} ->
            hot_touched = Enum.filter(spots, fn s -> s.module in modules_touched end)
            Enum.reduce(hot_touched, recs, fn s, acc ->
              ["LIVE: #{s.module} is currently at #{s.reductions_pct}% CPU — consider deferring modifications" | acc]
            end)
          _ -> recs
        end
      else
        recs
      end

    Enum.reverse(recs)
  rescue
    _ -> []
  end

  # Strip internal fields from checks before returning
  defp sanitize_check(check) do
    Map.take(check, [:check, :status, :detail])
  end
end
