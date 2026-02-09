defmodule Giulia.Inference.Trace do
  @moduledoc """
  Stores the last inference trace for debugging.

  The Architect's first rule: "We can't debug what we can't see."
  This module captures what the orchestrator did so we can diagnose failures.
  """
  use Agent

  @doc """
  Start the trace storage.
  """
  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Store a trace from a completed orchestrator run.
  """
  def store(trace) when is_map(trace) do
    Agent.update(__MODULE__, fn _ ->
      Map.put(trace, :stored_at, DateTime.utc_now())
    end)
  end

  @doc """
  Get the last stored trace.
  """
  def get_last do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Build a trace map from orchestrator state.
  """
  def from_orchestrator_state(state) do
    %{
      task: state.task,
      project_path: state.project_path,
      status: to_string(state.status),
      iteration: state.counters.iteration,
      max_iterations: state.counters.max_iterations,
      consecutive_failures: state.counters.consecutive_failures,
      provider: if(state.provider.name, do: to_string(state.provider.name), else: nil),
      action_history: format_action_history(state.action_history),
      recent_errors: Enum.map(state.recent_errors, &inspect/1),
      last_action: format_action(state.last_action),
      final_response: state.final_response
    }
  end

  defp format_action_history(history) do
    Enum.map(history, fn {tool, params, result} ->
      %{
        tool: tool,
        params: truncate_params(params),
        result: format_result(result)
      }
    end)
  end

  defp format_action(nil), do: nil
  defp format_action({tool, params}) do
    %{tool: tool, params: truncate_params(params)}
  end

  defp truncate_params(params) when is_map(params) do
    Map.new(params, fn {k, v} ->
      v_str = if is_binary(v) and String.length(v) > 100 do
        String.slice(v, 0, 100) <> "..."
      else
        v
      end
      {k, v_str}
    end)
  end
  defp truncate_params(params), do: params

  # Convert tuples to JSON-encodable format
  defp format_result({:ok, content}) when is_binary(content) do
    truncated = if String.length(content) > 200 do
      String.slice(content, 0, 200) <> "..."
    else
      content
    end
    ["ok", truncated]
  end

  defp format_result({:ok, content}) do
    ["ok", inspect(content, limit: 50)]
  end

  defp format_result({:error, reason}) do
    ["error", inspect(reason, limit: 100)]
  end

  defp format_result(other) do
    inspect(other, limit: 100)
  end
end
