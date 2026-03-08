defmodule Giulia.Runtime.Profiler do
  @moduledoc """
  Performance Profile Generator — Pure Functions, No LLM.

  Takes burst snapshots from the Collector + Giulia's Knowledge Graph
  + per-function cognitive complexity and produces a fused performance
  profile. Fully offline, sub-millisecond generation.

  ## Output

  A map with peak metrics, hot modules (fused with KG data and complexity),
  and template-generated bottleneck analysis strings.
  """

  alias Giulia.Context.Store
  alias Giulia.Knowledge.Store, as: KnowledgeStore

  @doc """
  Produce a performance profile from burst snapshots.

  Args:
    - `snapshots` — list of runtime snapshots from the burst window
    - `project_path` — Giulia's project path (for KG + complexity lookup)
    - `opts` — optional overrides (`:top_n` for hot module count, default 10)

  Returns a profile map with metrics, hot modules, and bottleneck analysis.
  """
  @spec produce(list(map()), String.t(), keyword()) :: map()
  def produce(snapshots, project_path, opts \\ []) do
    top_n = Keyword.get(opts, :top_n, 10)

    timestamps = Enum.map(snapshots, & &1[:timestamp])
    pulses = Enum.map(snapshots, & &1[:pulse])

    # Peak metrics from the burst window
    peak = compute_peaks(pulses)

    # Memory delta (first vs peak)
    first_mem = get_in(List.first(pulses) || %{}, [:beam, :memory_mb]) || 0
    memory_delta = Float.round(peak.peak_memory_mb - first_mem, 1)

    # Aggregate top_processes across all snapshots
    hot_modules = aggregate_hot_modules(snapshots, project_path, top_n)

    # Template-generated bottleneck analysis
    analysis = generate_analysis(hot_modules, peak)

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: compute_duration(timestamps),
      snapshot_count: length(snapshots),
      peak_memory_mb: peak.peak_memory_mb,
      memory_delta_mb: memory_delta,
      peak_process_count: peak.peak_process_count,
      peak_run_queue: peak.peak_run_queue,
      peak_ets_memory_mb: peak.peak_ets_memory_mb,
      hot_modules: hot_modules,
      bottleneck_analysis: analysis
    }
  end

  # ============================================================================
  # Peak Computation
  # ============================================================================

  defp compute_peaks(pulses) do
    Enum.reduce(pulses, %{peak_memory_mb: 0, peak_process_count: 0, peak_run_queue: 0, peak_ets_memory_mb: 0}, fn pulse, acc ->
      beam = pulse[:beam] || %{}
      ets = pulse[:ets] || %{}

      %{
        peak_memory_mb: max(acc.peak_memory_mb, beam[:memory_mb] || 0),
        peak_process_count: max(acc.peak_process_count, beam[:processes] || 0),
        peak_run_queue: max(acc.peak_run_queue, beam[:run_queue] || 0),
        peak_ets_memory_mb: max(acc.peak_ets_memory_mb, ets[:total_memory_mb] || 0)
      }
    end)
  end

  # ============================================================================
  # Hot Module Aggregation
  # ============================================================================

  defp aggregate_hot_modules(snapshots, project_path, top_n) do
    # Collect all top_processes entries across all snapshots
    all_procs =
      snapshots
      |> Enum.flat_map(fn s -> s[:top_processes] || [] end)
      |> Enum.filter(fn p -> is_binary(p[:module]) or is_atom(p[:module]) end)

    # Group by module, sum reductions
    by_module =
      Enum.group_by(all_procs, fn p ->
        mod = p[:module]
        if is_atom(mod), do: Atom.to_string(mod), else: mod
      end)

    total_reductions =
      Enum.reduce(all_procs, 0, fn p, acc -> acc + (p[:reductions] || p[:metric_value] || 0) end)

    by_module
    |> Enum.map(fn {mod_name, entries} ->
      # Peak reductions and memory for this module
      max_reductions = entries |> Enum.map(& (&1[:reductions] || &1[:metric_value] || 0)) |> Enum.max(fn -> 0 end)
      max_memory_kb = entries |> Enum.map(& (&1[:memory_kb] || 0)) |> Enum.max(fn -> 0 end)
      appearances = length(entries)

      reductions_pct =
        if total_reductions > 0,
          do: Float.round(max_reductions / total_reductions * 100, 1),
          else: 0.0

      # Fuse with Knowledge Graph
      kg_data = lookup_kg(mod_name, project_path)

      # Fuse with per-function cognitive complexity
      hottest_functions = lookup_complexity(mod_name, project_path)

      %{
        module: mod_name,
        reductions_pct: reductions_pct,
        max_reductions: max_reductions,
        memory_kb: max_memory_kb,
        appearances: appearances,
        knowledge_graph: kg_data,
        hottest_functions: hottest_functions
      }
    end)
    |> Enum.filter(fn m -> not String.starts_with?(m.module, ":") end)  # Skip OTP internals
    |> Enum.sort_by(& &1.max_reductions, :desc)
    |> Enum.take(top_n)
  end

  defp lookup_kg(mod_name, project_path) do
    case KnowledgeStore.centrality(project_path, mod_name) do
      {:ok, data} ->
        %{
          in_degree: data[:in_degree] || 0,
          out_degree: data[:out_degree] || 0,
          hub_score: (data[:in_degree] || 0) + (data[:out_degree] || 0)
        }

      _ ->
        nil
    end
  end

  defp lookup_complexity(mod_name, project_path) do
    case Store.list_functions(project_path, mod_name) do
      functions when is_list(functions) and functions != [] ->
        functions
        |> Enum.filter(fn f -> (f[:complexity] || 0) > 0 end)
        |> Enum.sort_by(& &1[:complexity], :desc)
        |> Enum.take(3)
        |> Enum.map(fn f ->
          %{
            name: f[:name],
            arity: f[:arity],
            complexity: f[:complexity]
          }
        end)

      _ ->
        []
    end
  end

  # ============================================================================
  # Bottleneck Analysis (Template-Generated)
  # ============================================================================

  defp generate_analysis(hot_modules, peak) do
    analysis = []

    # CPU bottlenecks (modules consuming >20% of reductions)
    analysis =
      hot_modules
      |> Enum.filter(fn m -> m.reductions_pct > 20 end)
      |> Enum.reduce(analysis, fn m, acc ->
        base = "#{m.module} consumed #{m.reductions_pct}% of CPU"

        detail =
          case m.hottest_functions do
            [top | _] when top.complexity > 5 ->
              "#{base}. #{top.name}/#{top.arity} has complexity #{top.complexity} — consider splitting."

            _ ->
              "#{base}."
          end

        [detail | acc]
      end)

    # Memory contributors (>10MB)
    analysis =
      hot_modules
      |> Enum.filter(fn m -> m.memory_kb > 10_000 end)
      |> Enum.reduce(analysis, fn m, acc ->
        mb = Float.round(m.memory_kb / 1024, 1)
        ["#{m.module} used #{mb}MB of memory — peak memory contributor." | acc]
      end)

    # Run queue pressure
    analysis =
      if peak.peak_run_queue > 3 do
        ["Run queue peaked at #{peak.peak_run_queue} — scheduler contention detected." | analysis]
      else
        analysis
      end

    # Memory growth
    analysis =
      if peak.peak_memory_mb > 256 do
        ["Peak memory reached #{peak.peak_memory_mb}MB — consider memory profiling." | analysis]
      else
        analysis
      end

    Enum.reverse(analysis)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp compute_duration(timestamps) do
    valid =
      timestamps
      |> Enum.filter(& &1)
      |> Enum.map(fn ts ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
          _ -> nil
        end
      end)
      |> Enum.filter(& &1)

    case valid do
      [] -> 0
      [_single] -> 0
      many -> Enum.max(many) - Enum.min(many)
    end
  end
end
