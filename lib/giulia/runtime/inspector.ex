defmodule Giulia.Runtime.Inspector do
  @moduledoc """
  BEAM Runtime Introspection — The Nerves.

  Exploits Distributed Erlang and local :erlang APIs to harvest runtime
  data from any running BEAM node. All operations are read-only with
  explicit timeouts — never modifies state on the target node.

  Node discovery (in order):
  1. Explicit `node` parameter
  2. `:local` — Giulia self-introspection (default)

  For remote nodes, use `connect/2` first with cookie authentication.
  """

  alias Giulia.Knowledge.Store, as: KnowledgeStore

  require Logger

  @rpc_timeout 5_000
  @top_n 10
  @hot_spots_n 5
  @trace_max_events 1_000
  @trace_max_duration 5_000

  # ============================================================================
  # Connection
  # ============================================================================

  @doc """
  Connect to a remote BEAM node with optional cookie override.

  Returns :ok if connection succeeds, error tuple otherwise.
  """
  @spec connect(atom(), keyword()) :: :ok | {:error, :node_unreachable | :auth_failed}
  def connect(node_name, opts \\ []) do
    # Set cookie if provided
    if cookie = opts[:cookie] do
      Node.set_cookie(node_name, String.to_atom(cookie))
    end

    case Node.connect(node_name) do
      true -> :ok
      false -> {:error, :node_unreachable}
      :ignored -> {:error, :auth_failed}
    end
  end

  # ============================================================================
  # Pulse — High-level BEAM Health
  # ============================================================================

  @doc """
  Returns high-level BEAM health for the target node.
  """
  @spec pulse(atom()) :: {:ok, map()} | {:error, term()}
  def pulse(node_ref \\ :local) do
    node = resolve_node(node_ref)

    with {:ok, memory} <- safe_rpc(node, :erlang, :memory, []),
         {:ok, process_count} <- safe_rpc(node, :erlang, :system_info, [:process_count]),
         {:ok, scheduler_count} <- safe_rpc(node, :erlang, :system_info, [:schedulers_online]),
         {:ok, run_queue} <- safe_rpc(node, :erlang, :statistics, [:run_queue]),
         {:ok, uptime_ms} <- safe_rpc(node, :erlang, :statistics, [:wall_clock]) do

      {uptime_total_ms, _since_last} = uptime_ms
      memory_mb = Float.round(memory[:total] / (1024 * 1024), 2)

      # ETS stats
      ets_tables = safe_rpc_default(node, :ets, :all, [], [])
      ets_info = collect_ets_info(node, ets_tables)

      # Warnings
      warnings = build_warnings(process_count, run_queue, memory_mb, ets_info)

      {:ok, %{
        node: node,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        beam: %{
          processes: process_count,
          memory_mb: memory_mb,
          memory_breakdown: %{
            processes_mb: Float.round(memory[:processes] / (1024 * 1024), 2),
            ets_mb: Float.round(memory[:ets] / (1024 * 1024), 2),
            atom_mb: Float.round(memory[:atom] / (1024 * 1024), 2),
            binary_mb: Float.round(memory[:binary] / (1024 * 1024), 2),
            code_mb: Float.round(memory[:code] / (1024 * 1024), 2)
          },
          schedulers: scheduler_count,
          uptime_seconds: div(uptime_total_ms, 1000),
          run_queue: run_queue
        },
        ets: %{
          tables: length(ets_tables),
          total_memory_mb: ets_info.total_memory_mb,
          god_tables: ets_info.god_tables
        },
        warnings: warnings
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Top Processes — Sorted by Metric
  # ============================================================================

  @doc """
  Returns top N processes by the given metric.

  Metrics: :reductions, :memory, :message_queue
  """
  @spec top_processes(atom(), atom()) :: {:ok, list(map())} | {:error, term()}
  def top_processes(node_ref \\ :local, metric \\ :reductions) do
    node = resolve_node(node_ref)

    case safe_rpc(node, :erlang, :processes, []) do
      {:ok, pids} ->
        info_key = metric_to_info_key(metric)

        results =
          pids
          |> Enum.map(fn pid -> fetch_process_info(node, pid, info_key) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(fn p -> p.metric_value end, :desc)
          |> Enum.take(@top_n)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Hot Spots — PID → Module → Knowledge Graph Fusion
  # ============================================================================

  @doc """
  Returns top N modules by runtime activity, fused with Knowledge Graph data.

  The differentiator: resolves PIDs to modules, then merges with static
  analysis data (complexity, centrality, zone) from the Knowledge Graph.
  """
  @spec hot_spots(atom(), String.t() | nil) :: {:ok, list(map())} | {:error, term()}
  def hot_spots(node_ref \\ :local, project_path \\ nil) do
    node = resolve_node(node_ref)

    case safe_rpc(node, :erlang, :processes, []) do
      {:ok, pids} ->
        # Collect per-module aggregated stats
        module_stats =
          pids
          |> Enum.map(fn pid -> fetch_process_info(node, pid, :reductions) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn p -> p.module != nil end)
          |> Enum.group_by(fn p -> p.module end)
          |> Enum.map(fn {module, procs} ->
            %{
              module: module,
              process_count: length(procs),
              reductions: Enum.sum(Enum.map(procs, & &1.metric_value)),
              memory_kb: Enum.sum(Enum.map(procs, & &1.memory_kb)),
              message_queue: Enum.sum(Enum.map(procs, & &1.message_queue))
            }
          end)
          |> Enum.sort_by(fn m -> m.reductions end, :desc)
          |> Enum.take(@hot_spots_n)

        # Total reductions for percentage calculation
        total_reductions = Enum.sum(Enum.map(module_stats, & &1.reductions))

        # Fuse with Knowledge Graph if project_path available
        fused =
          Enum.map(module_stats, fn mod ->
            reductions_pct =
              if total_reductions > 0,
                do: Float.round(mod.reductions / total_reductions * 100, 1),
                else: 0.0

            graph_data = fetch_graph_data(project_path, mod.module)

            Map.merge(mod, %{
              reductions_pct: reductions_pct,
              knowledge_graph: graph_data
            })
          end)

        {:ok, fused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Trace — Short-lived Per-module Call Frequency
  # ============================================================================

  @doc """
  Short-lived per-module function call tracing with kill switch.

  Hard limits (non-negotiable):
  - Max events: #{@trace_max_events}
  - Max duration: #{@trace_max_duration}ms
  - Whichever comes first wins

  Only works on local node — tracing on remote nodes via :rpc is unsafe.
  """
  @spec trace(atom(), atom() | String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def trace(node_ref \\ :local, module, duration_ms \\ 5_000) do
    node = resolve_node(node_ref)

    # Clamp duration
    actual_duration = min(duration_ms, @trace_max_duration)

    # Resolve module atom
    module_atom =
      if is_binary(module) do
        module
        |> ensure_elixir_prefix()
        |> String.to_existing_atom()
      else
        module
      end

    if node == node() do
      trace_local(module_atom, actual_duration)
    else
      trace_remote(node, module_atom, actual_duration)
    end
  rescue
    ArgumentError ->
      {:error, {:unknown_module, module}}
  end

  # ============================================================================
  # Local Trace Implementation
  # ============================================================================

  defp trace_local(module_atom, duration_ms) do
    parent = self()
    ref = make_ref()

    # Spawn a collector process that receives trace messages
    collector = spawn(fn -> trace_collector_loop(parent, ref, %{}, 0) end)

    # Set up tracing — all calls to the target module
    :erlang.trace(collector, true, [:receive])

    # Match spec: trace all function calls in the module
    match_spec = [{:_, [], [{:return_trace}]}]

    try do
      :erlang.trace_pattern({module_atom, :_, :_}, match_spec, [:local])
      :erlang.trace(:all, true, [{:tracer, collector}, :call])

      # Wait for duration or kill switch
      Process.send_after(self(), {:trace_timeout, ref}, duration_ms)

      receive do
        {:trace_timeout, ^ref} -> :ok
        {:trace_overflow, ^ref} -> :ok
      end
    after
      # Always clean up tracing
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({module_atom, :_, :_}, false, [:local])
    end

    # Collect results from the collector process
    send(collector, {:get_results, ref, self()})

    receive do
      {:trace_results, ^ref, counts, total, aborted} ->
        calls =
          counts
          |> Enum.map(fn {{func, arity}, count} ->
            %{function: func, arity: arity, count: count}
          end)
          |> Enum.sort_by(& &1.count, :desc)

        result = %{
          module: inspect(module_atom),
          duration_ms: duration_ms,
          aborted: aborted,
          calls: calls,
          total_calls: total,
          calls_per_second: Float.round(total / (duration_ms / 1000), 1)
        }

        if aborted do
          {:ok, Map.put(result, :reason, "High-frequency function detected (>#{@trace_max_events} events). Use sampling instead.")}
        else
          {:ok, result}
        end
    after
      2_000 ->
        {:error, :trace_collector_timeout}
    end
  end

  defp trace_collector_loop(parent, ref, counts, total) do
    if total >= @trace_max_events do
      send(parent, {:trace_overflow, ref})
      trace_collector_wait(counts, total, true, ref)
    else
      receive do
        {:trace, _pid, :call, {_mod, func, args}} ->
          arity = length(args)
          key = {func, arity}
          new_counts = Map.update(counts, key, 1, &(&1 + 1))
          trace_collector_loop(parent, ref, new_counts, total + 1)

        {:get_results, ^ref, reply_to} ->
          send(reply_to, {:trace_results, ref, counts, total, false})

        _other ->
          trace_collector_loop(parent, ref, counts, total)
      after
        10_000 ->
          send(parent, {:trace_results, ref, counts, total, false})
      end
    end
  end

  defp trace_collector_wait(counts, total, aborted, ref) do
    receive do
      {:get_results, ^ref, reply_to} ->
        send(reply_to, {:trace_results, ref, counts, total, aborted})

      {:trace, _, :call, _} ->
        # Discard overflow events
        trace_collector_wait(counts, total, aborted, ref)

      _other ->
        trace_collector_wait(counts, total, aborted, ref)
    after
      10_000 -> :ok
    end
  end

  defp trace_remote(_node, _module_atom, _duration_ms) do
    # Remote tracing is intentionally not supported — too dangerous
    {:error, :remote_trace_not_supported}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp resolve_node(:local), do: node()
  defp resolve_node(node_name) when is_atom(node_name), do: node_name

  defp resolve_node(node_name) when is_binary(node_name) do
    String.to_existing_atom(node_name)
  rescue
    ArgumentError -> node()
  end

  defp safe_rpc(node, mod, fun, args) when node == node() do
    {:ok, apply(mod, fun, args)}
  rescue
    e -> {:error, {:local_error, Exception.message(e)}}
  end

  defp safe_rpc(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args, @rpc_timeout) do
      {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      result -> {:ok, result}
    end
  end

  defp safe_rpc_default(node, mod, fun, args, default) do
    case safe_rpc(node, mod, fun, args) do
      {:ok, result} -> result
      {:error, _} -> default
    end
  end

  defp metric_to_info_key(:reductions), do: :reductions
  defp metric_to_info_key(:memory), do: :memory
  defp metric_to_info_key(:message_queue), do: :message_queue_len
  defp metric_to_info_key(_), do: :reductions

  defp fetch_process_info(node, pid, metric_key) do
    info_keys = [:registered_name, :initial_call, :current_function,
                 :reductions, :memory, :message_queue_len]

    case safe_rpc(node, :erlang, :process_info, [pid, info_keys]) do
      {:ok, info} when is_list(info) ->
        registered = info[:registered_name]
        {mod, _fun, _arity} = info[:initial_call] || {nil, nil, nil}
        current_fn = info[:current_function]
        memory_kb = Float.round((info[:memory] || 0) / 1024, 1)

        module_name = resolve_module_name(registered, mod)

        metric_value =
          case metric_key do
            :reductions -> info[:reductions] || 0
            :memory -> info[:memory] || 0
            :message_queue_len -> info[:message_queue_len] || 0
            _ -> info[:reductions] || 0
          end

        %{
          pid: inspect(pid),
          registered_name: if(registered && registered != [], do: inspect(registered), else: nil),
          module: module_name,
          metric_value: metric_value,
          reductions: info[:reductions] || 0,
          memory_kb: memory_kb,
          message_queue: info[:message_queue_len] || 0,
          current_function: format_mfa(current_fn)
        }

      _ ->
        nil
    end
  end

  defp resolve_module_name(registered, initial_mod) do
    cond do
      is_atom(registered) and registered not in [nil, []] ->
        registered |> inspect() |> clean_module_name()

      is_atom(initial_mod) and initial_mod != nil ->
        initial_mod |> inspect() |> clean_module_name()

      true ->
        nil
    end
  end

  defp clean_module_name("Elixir." <> rest), do: rest
  defp clean_module_name(name), do: name

  defp format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp format_mfa(_), do: nil

  defp collect_ets_info(node, tables) do
    word_size = :erlang.system_info(:wordsize)

    table_info =
      tables
      |> Enum.map(fn tab ->
        # Single call per table instead of 3 separate calls
        case safe_rpc(node, :ets, :info, [tab]) do
          {:ok, info} when is_list(info) ->
            name = Keyword.get(info, :name, tab)
            size = Keyword.get(info, :size, 0)
            memory_words = Keyword.get(info, :memory, 0)
            memory_mb = Float.round(memory_words * word_size / (1024 * 1024), 3)
            %{name: inspect(name), size: size, memory_mb: memory_mb}

          _ ->
            %{name: inspect(tab), size: 0, memory_mb: 0.0}
        end
      end)
      |> Enum.sort_by(& &1.memory_mb, :desc)

    total_mb = Enum.sum(Enum.map(table_info, & &1.memory_mb)) |> Float.round(2)
    god_tables = Enum.take(table_info, 5)

    %{total_memory_mb: total_mb, god_tables: god_tables}
  end

  defp build_warnings(process_count, run_queue, memory_mb, ets_info) do
    warnings = []

    warnings =
      if process_count > 100_000,
        do: ["High process count: #{process_count}" | warnings],
        else: warnings

    warnings =
      if run_queue > 10,
        do: ["Run queue pressure: #{run_queue}" | warnings],
        else: warnings

    warnings =
      if memory_mb > 1024,
        do: ["High memory usage: #{memory_mb}MB" | warnings],
        else: warnings

    warnings =
      if ets_info.total_memory_mb > 512,
        do: ["Large ETS footprint: #{ets_info.total_memory_mb}MB" | warnings],
        else: warnings

    Enum.reverse(warnings)
  end

  defp fetch_graph_data(nil, _module), do: nil

  defp fetch_graph_data(project_path, module_name) do
    # Try to get centrality and heatmap data for this module
    centrality =
      case KnowledgeStore.centrality(project_path, module_name) do
        {:ok, result} -> result
        _ -> nil
      end

    heatmap_entry = get_heatmap_entry(project_path, module_name)

    if centrality || heatmap_entry do
      %{
        in_degree: centrality[:in_degree],
        out_degree: centrality[:out_degree],
        total_degree: centrality[:total_degree],
        zone: heatmap_entry[:zone],
        score: heatmap_entry[:score],
        complexity: heatmap_entry[:breakdown][:complexity]
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp get_heatmap_entry(project_path, module_name) do
    case KnowledgeStore.heatmap(project_path) do
      {:ok, %{modules: modules}} ->
        Enum.find(modules, fn m ->
          (m[:module] || m["module"]) == module_name
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp ensure_elixir_prefix("Elixir." <> _ = name), do: name
  defp ensure_elixir_prefix(name), do: "Elixir." <> name
end
