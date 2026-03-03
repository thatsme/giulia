defmodule Giulia.Inference.Engine.Step do
  @moduledoc """
  Handles all `:step` dispatch clauses — guard checks, batched tool queue,
  and the normal LLM call + response routing.

  Extracted from Engine in build 112.
  """

  require Logger

  alias Giulia.Tools.Registry
  alias Giulia.Inference.{ContextBuilder, State, ToolDispatch}
  alias Giulia.Inference.Engine.{Helpers, Response}

  @doc """
  Run one step of the inference loop.

  Guards (in order):
  1. Paused / waiting for approval → halt
  2. Max iterations → done
  3. Max failures → intervene
  4. Pending batched tool calls → execute next
  5. Normal → call LLM, route response
  """
  @spec run(State.t()) :: Giulia.Inference.Engine.directive()

  def run(%{status: :paused} = state), do: {:halt, state}
  def run(%{status: :waiting_for_approval} = state), do: {:halt, state}

  def run(%{counters: %{iteration: iter, max_iterations: max}} = state)
      when iter >= max do
    Logger.warning("Max iterations reached (#{max})")
    Helpers.done_with_telemetry({:error, :max_iterations_exceeded}, state)
  end

  def run(%{counters: %{consecutive_failures: f, max_failures: max}} = state)
      when f >= max do
    Logger.warning("Max consecutive failures (#{max}), intervening...")
    {:next, :intervene, state}
  end

  def run(%{pending_tool_calls: [next | rest]} = state) do
    state = state |> State.increment_iteration() |> State.set_pending_tool_calls(rest) |> State.set_status(:thinking)
    tool_name = next["tool"]
    params = next["parameters"] || %{}
    Logger.info("Multi-action queue: executing #{tool_name} (#{length(rest)} remaining)")

    synthetic_content = Jason.encode!(%{tool: tool_name, parameters: params})
    synthetic_response = %{content: synthetic_content, tool_calls: nil}

    ToolDispatch.execute(tool_name, params, synthetic_response, state)
  end

  def run(state) do
    state = state |> State.increment_iteration() |> State.set_status(:thinking)
    Logger.debug("Inference loop iteration #{State.iteration(state)}")

    :telemetry.execute(
      [:giulia, :inference, :step],
      %{iteration: State.iteration(state), system_time: System.system_time(:millisecond)},
      %{status: state.status, provider: state.provider.name, request_id: state.request_id}
    )

    messages = ContextBuilder.inject_distilled_context(state.messages, state)

    t0 = System.monotonic_time(:millisecond)

    case call_provider(State.set_messages(state, messages)) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        :telemetry.execute(
          [:giulia, :llm, :call],
          %{duration_ms: duration_ms, system_time: System.system_time(:millisecond)},
          %{provider: state.provider.name, status: :ok, request_id: state.request_id}
        )

        Response.handle_model_response(response, state)

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        :telemetry.execute(
          [:giulia, :llm, :call],
          %{duration_ms: duration_ms, system_time: System.system_time(:millisecond)},
          %{provider: state.provider.name, status: :error, request_id: state.request_id}
        )

        Logger.error("Provider error: #{inspect(reason)}")
        state = state |> State.increment_failures() |> State.push_error(reason)
        {:next, :step, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp call_provider(%{provider: %{module: module}, messages: messages}) do
    tools = Registry.list_tools()
    module.chat(messages, tools, timeout: 300_000)
  end
end
