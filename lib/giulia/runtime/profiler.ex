defmodule Giulia.Runtime.Profiler do
  @moduledoc """
  Performance Profile Generator — Build 132.

  Pure function module (no GenServer). Takes burst snapshots from the Collector
  and fuses them with Giulia's Knowledge Graph and per-function cognitive
  complexity data to produce a structured performance profile.

  ## Fully Offline

  All analysis is template-generated, not LLM-powered. The profiler has zero
  provider dependency. Sub-millisecond generation.

  ## Input

  - List of runtime snapshots from the burst window (pulse + top_processes at 500ms)
  - Giulia's project path (for Knowledge Graph + complexity lookups)

  ## Output

  A profile map with duration, peak metrics, hot modules (fused with static
  analysis), and template-generated bottleneck analysis strings.
  """

  alias Giulia.Knowledge.Store, as: KnowledgeStore
  # Context.Store.Query used directly (fully qualified) in fetch_hottest_functions

  @doc """
  Produce a performance profile from burst snapshots.

  Options:
  - `:burst_start` — DateTime when the burst was first detected (for duration calc)
  """
  @spec produce_profile(list(map()), String.t(), keyword()) :: map()
  def produce_profile(snapshots, project_path, opts \\ []) do
    burst_start = Keyword.get(opts, :burst_start)
    burst_end = DateTime.utc_now()

    duration_ms = calculate_duration(burst_start, burst_end, snapshots)
    peak_metrics = calculate_peak_metrics(snapshots)
    hot_modules = build_hot_modules(snapshots, project_path)
    bottleneck_analysis = generate_bottleneck_analysis(hot_modules, peak_metrics)

    %{
      timestamp: DateTime.to_iso8601(burst_end),
      duration_ms: duration_ms,
      snapshot_count: length(snapshots),
      peak: peak_metrics,
      hot_modules: hot_modules,
      bottleneck_analysis: bottleneck_analysis
    }
  end

  # ============================================================================
  # Duration
  # ============================================================================

  defp calculate_duration(nil, _burst_end, snapshots) do
    # No burst_start recorded — estimate from snapshot timestamps
    case {List.first(snapshots), List.last(snapshots)} do
      {nil, _} -> 0
      {_, nil} -> 0
      {first, last} ->
        t1 = get_snapshot_timestamp(first)
        t2 = get_snapshot_timestamp(last)
        if t1 && t2, do: DateTime.diff(t2, t1, :millisecond), else: 0
    end
  end

  defp calculate_duration(burst_start, burst_end, _snapshots) do
    DateTime.diff(burst_end, burst_start, :millisecond)
  end

  defp get_snapshot_timestamp(%{pulse: %{timestamp: ts}}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp get_snapshot_timestamp(%{timestamp: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp get_snapshot_timestamp(_), do: nil

  # ============================================================================
  # Peak Metrics
  # ============================================================================

  defp calculate_peak_metrics(snapshots) do
    pulses = Enum.reject(Enum.map(snapshots, fn s -> s[:pulse] end), &is_nil/1)

    if Enum.empty?(pulses) do
      %{memory_mb: 0, memory_delta_mb: 0, process_count: 0, run_queue: 0}
    else
      memories = Enum.map(pulses, fn p -> get_in(p, [:beam, :memory_mb]) || 0 end)
      process_counts = Enum.map(pulses, fn p -> get_in(p, [:beam, :processes]) || 0 end)
      run_queues = Enum.map(pulses, fn p -> get_in(p, [:beam, :run_queue]) || 0 end)

      first_mem = List.first(memories) || 0
      peak_mem = Enum.max(memories, fn -> 0 end)

      %{
        memory_mb: Float.round(peak_mem * 1.0, 1),
        memory_delta_mb: Float.round((peak_mem - first_mem) * 1.0, 1),
        process_count: Enum.max(process_counts, fn -> 0 end),
        run_queue: Enum.max(run_queues, fn -> 0 end)
      }
    end
  end

  # ============================================================================
  # Hot Modules — Fused with Knowledge Graph + Complexity
  # ============================================================================

  defp build_hot_modules(snapshots, project_path) do
    # Aggregate top_processes across all snapshots
    all_procs =
      snapshots
      |> Enum.flat_map(fn s -> s[:top_processes] || [] end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(all_procs) do
      []
    else
      # Group by module, sum reductions
      module_stats =
        all_procs
        |> Enum.filter(fn p -> p[:module] != nil end)
        |> Enum.group_by(fn p -> p[:module] end)
        |> Enum.map(fn {module, procs} ->
          %{
            module: module,
            total_reductions: Enum.sum(Enum.map(procs, fn p -> p[:reductions] || p[:metric_value] || 0 end)),
            total_memory_kb: Enum.sum(Enum.map(procs, fn p -> p[:memory_kb] || 0 end)),
            sample_count: length(procs)
          }
        end)
        |> Enum.sort_by(& &1.total_reductions, :desc)
        |> Enum.take(10)

      total_reductions = Enum.sum(Enum.map(module_stats, & &1.total_reductions))

      Enum.map(module_stats, fn mod ->
        reductions_pct =
          if total_reductions > 0,
            do: Float.round(mod.total_reductions / total_reductions * 100, 1),
            else: 0.0

        memory_mb = Float.round(mod.total_memory_kb / 1024, 2)

        # Fuse with Knowledge Graph
        kg_data = fetch_knowledge_graph_data(project_path, mod.module)

        # Get hottest functions by cognitive complexity
        hottest_fns = fetch_hottest_functions(project_path, mod.module)

        %{
          module: mod.module,
          reductions_pct: reductions_pct,
          memory_mb: memory_mb,
          sample_count: mod.sample_count,
          knowledge_graph: kg_data,
          hottest_functions: hottest_fns
        }
      end)
    end
  end

  defp fetch_knowledge_graph_data(nil, _module), do: nil

  defp fetch_knowledge_graph_data(project_path, module_name) do
    centrality =
      case KnowledgeStore.centrality(project_path, module_name) do
        {:ok, result} -> result
        _ -> nil
      end

    heatmap_entry =
      case KnowledgeStore.heatmap(project_path) do
        {:ok, %{modules: modules}} ->
          Enum.find(modules, fn m ->
            (m[:module] || m["module"]) == module_name
          end)

        _ ->
          nil
      end

    if centrality || heatmap_entry do
      %{
        in_degree: centrality[:in_degree],
        out_degree: centrality[:out_degree],
        zone: heatmap_entry[:zone],
        score: heatmap_entry[:score]
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp fetch_hottest_functions(nil, _module), do: []

  defp fetch_hottest_functions(project_path, module_name) do
    # Get functions from Context.Store and find those with complexity data
    case Giulia.Context.Store.Query.list_functions(project_path, module_name) do
      functions when is_list(functions) and functions != [] ->
        functions
        |> Enum.filter(fn f -> (f[:complexity] || 0) >= 5 end)
        |> Enum.sort_by(fn f -> f[:complexity] || 0 end, :desc)
        |> Enum.take(3)
        |> Enum.map(fn f ->
          %{
            name: f[:name],
            arity: f[:arity],
            cognitive_complexity: f[:complexity] || 0
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # ============================================================================
  # Bottleneck Analysis — Template-Generated (No LLM)
  # ============================================================================

  defp generate_bottleneck_analysis(hot_modules, peak_metrics) do
    analyses = []

    # CPU bottleneck analysis
    analyses =
      case hot_modules do
        [top | _] when top.reductions_pct > 30 ->
          base = "#{top.module} consumed #{top.reductions_pct}% of CPU"

          detail =
            case top.hottest_functions do
              [%{name: name, arity: arity, cognitive_complexity: cc} | _] when cc >= 5 ->
                ". #{name}/#{arity} has complexity #{cc} — consider splitting."

              _ ->
                "."
            end

          [base <> detail | analyses]

        _ ->
          analyses
      end

    # Memory analysis
    analyses =
      case Enum.find(hot_modules, fn m -> m.memory_mb > 10 end) do
        nil ->
          analyses

        mem_hog ->
          ["#{mem_hog.module} allocated #{mem_hog.memory_mb}MB — peak memory contributor." | analyses]
      end

    # Run queue analysis
    analyses =
      if peak_metrics.run_queue > 2 do
        ["Run queue peaked at #{peak_metrics.run_queue} — scheduler contention detected." | analyses]
      else
        analyses
      end

    # Memory growth analysis
    analyses =
      if peak_metrics.memory_delta_mb > 50 do
        ["Memory grew by #{peak_metrics.memory_delta_mb}MB during burst — investigate allocations." | analyses]
      else
        analyses
      end

    Enum.reverse(analyses)
  end
end
