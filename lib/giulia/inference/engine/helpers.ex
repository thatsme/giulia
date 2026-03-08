defmodule Giulia.Inference.Engine.Helpers do
  @moduledoc """
  Shared cross-cutting helpers used by Engine sub-modules.

  Extracted from Engine in build 112.
  """

  alias Giulia.Inference.{ContextBuilder, Events, State, Verification}

  @doc """
  Emit `[:giulia, :inference, :done]` telemetry and return `{:done, result, state}`.
  """
  @spec done_with_telemetry(term(), State.t()) :: {:done, term(), State.t()}
  def done_with_telemetry(result, state) do
    result_type = case result do
      {:ok, _} -> :ok
      {:error, _} -> :error
      _ -> :unknown
    end

    :telemetry.execute(
      [:giulia, :inference, :done],
      %{total_iterations: State.iteration(state), system_time: System.system_time(:millisecond)},
      %{result_type: result_type, request_id: state.request_id}
    )

    {:done, result, state}
  end

  @doc """
  Broadcast an SSE event if the state has a request_id. No-op otherwise.
  """
  @spec maybe_broadcast(State.t(), map()) :: :ok
  def maybe_broadcast(%{request_id: nil}, _event), do: :ok
  def maybe_broadcast(%{request_id: id}, event), do: Events.broadcast(id, event)

  @doc """
  Broadcast escalation failure via SSE events.
  """
  def broadcast_escalation_failed(state, message) do
    maybe_broadcast(state, %{type: :escalation_failed, message: message})
  end

  @doc """
  Build a BUILD GREEN observation from verification result and append to messages.
  Returns `{:next, :step, state}`.
  """
  def build_green_observation(tool_name, result, warnings, state, test_summary) do
    test_hint = ContextBuilder.build_test_hint(state)
    observation = Verification.build_green_observation(tool_name, result, warnings, test_hint, test_summary)
    messages = state.messages ++ [%{role: "user", content: observation}]
    state = State.set_messages(state, messages)
    {:next, :step, state}
  end
end
