defmodule Giulia.Runtime.Inspector.Trace do
  @moduledoc """
  Short-lived per-module function call tracing with kill switch.

  Spawns a collector process that receives `:erlang.trace` messages,
  aggregates call counts per {function, arity}, and returns results
  when the duration expires or the event limit is reached.

  Hard limits (non-negotiable):
  - Max events: 1,000
  - Max duration: 5,000ms
  - Whichever comes first wins

  Only works on local node — tracing on remote nodes via :rpc is unsafe.

  Extracted from `Runtime.Inspector` (Build 128).
  """

  @trace_max_events 1_000
  @trace_max_duration 5_000

  @spec run(atom(), atom() | String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def run(node_ref \\ :local, module, duration_ms \\ 5_000) do
    node = resolve_node(node_ref)
    actual_duration = min(duration_ms, @trace_max_duration)

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
      {:error, :remote_trace_not_supported}
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

    collector = spawn(fn -> collector_loop(parent, ref, %{}, 0) end)

    :erlang.trace(collector, true, [:receive])

    match_spec = [{:_, [], [{:return_trace}]}]

    try do
      :erlang.trace_pattern({module_atom, :_, :_}, match_spec, [:local])
      :erlang.trace(:all, true, [{:tracer, collector}, :call])

      Process.send_after(self(), {:trace_timeout, ref}, duration_ms)

      receive do
        {:trace_timeout, ^ref} -> :ok
        {:trace_overflow, ^ref} -> :ok
      end
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({module_atom, :_, :_}, false, [:local])
    end

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
          calls_per_second: if(duration_ms > 0, do: Float.round(total / (duration_ms / 1000), 1), else: 0.0)
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

  defp collector_loop(parent, ref, counts, total) do
    if total >= @trace_max_events do
      send(parent, {:trace_overflow, ref})
      collector_wait(counts, total, true, ref)
    else
      receive do
        {:trace, _pid, :call, {_mod, func, args}} ->
          arity = length(args)
          key = {func, arity}
          new_counts = Map.update(counts, key, 1, &(&1 + 1))
          collector_loop(parent, ref, new_counts, total + 1)

        {:get_results, ^ref, reply_to} ->
          send(reply_to, {:trace_results, ref, counts, total, false})

        _other ->
          collector_loop(parent, ref, counts, total)
      after
        10_000 ->
          send(parent, {:trace_results, ref, counts, total, false})
      end
    end
  end

  defp collector_wait(counts, total, aborted, ref) do
    receive do
      {:get_results, ^ref, reply_to} ->
        send(reply_to, {:trace_results, ref, counts, total, aborted})

      {:trace, _, :call, _} ->
        collector_wait(counts, total, aborted, ref)

      _other ->
        collector_wait(counts, total, aborted, ref)
    after
      10_000 -> :ok
    end
  end

  # ============================================================================
  # Helpers (duplicated from Inspector — tiny, no coupling needed)
  # ============================================================================

  defp resolve_node(:local), do: node()
  defp resolve_node(node_name) when is_atom(node_name), do: node_name

  defp resolve_node(node_name) when is_binary(node_name) do
    String.to_existing_atom(node_name)
  rescue
    ArgumentError -> node()
  end

  defp ensure_elixir_prefix("Elixir." <> _ = name), do: name
  defp ensure_elixir_prefix(name), do: "Elixir." <> name
end
