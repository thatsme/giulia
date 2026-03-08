defmodule Giulia.Inference.ToolDispatch.Approval do
  @moduledoc """
  Approval gating and callback handling for tool execution.
  Extracted from ToolDispatch in Build 114.
  """

  require Logger

  alias Giulia.Inference.{Approval, ContextBuilder, State}
  alias Giulia.Inference.Engine.Helpers

  # ============================================================================
  # Approval Flow
  # ============================================================================

  @doc "Request user approval before executing a tool, then halt the loop."
  @spec execute_with_approval(String.t(), map(), map(), map()) :: {:halt, map()}
  def execute_with_approval(tool_name, params, response, state) do
    Logger.info("Tool #{tool_name} requires approval - entering wait state")

    preview = ContextBuilder.generate_preview(tool_name, params, state)
    approval_id = "approval-#{:erlang.phash2(state.request_id)}-#{State.iteration(state)}"

    hub_warning = ContextBuilder.assess_hub_risk(tool_name, params, state.project_path)

    preview =
      if hub_warning do
        "#{hub_warning}\n\n#{preview}"
      else
        preview
      end

    broadcast_payload = %{
      type: :tool_requires_approval,
      approval_id: approval_id,
      iteration: State.iteration(state),
      tool: tool_name,
      params: ContextBuilder.sanitize_params_for_broadcast(params),
      preview: preview
    }

    broadcast_payload =
      if hub_warning do
        Map.put(broadcast_payload, :hub_risk, :high)
      else
        broadcast_payload
      end

    Helpers.maybe_broadcast(state, broadcast_payload)

    Approval.request_approval_async(
      approval_id,
      tool_name,
      params,
      preview,
      self(),
      timeout: 300_000
    )

    pending = %{
      approval_id: approval_id,
      tool: tool_name,
      params: params,
      response: response
    }

    state = state |> State.set_status(:waiting_for_approval) |> State.set_pending_approval(pending)

    {:halt, state}
  end

  # ============================================================================
  # Approval Callbacks
  # ============================================================================

  @doc "Handle an approved tool call — execute directly."
  @spec handle_approved(map(), map(), (String.t(), map(), map(), map() -> tuple())) :: tuple()
  def handle_approved(pending, state, execute_direct_fn) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.info("Approval granted for #{tool_name}")

    Helpers.maybe_broadcast(state, %{
      type: :approval_granted,
      approval_id: pending.approval_id,
      tool: tool_name
    })

    execute_direct_fn.(tool_name, params, response, state)
  end

  @doc "Handle a rejected tool call — inject feedback."
  @spec handle_rejected(map(), map()) :: {:next, :step, map()}
  def handle_rejected(pending, state) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.info("Approval rejected for #{tool_name}")

    Helpers.maybe_broadcast(state, %{
      type: :approval_rejected,
      approval_id: pending.approval_id,
      tool: tool_name
    })

    handle_rejection(tool_name, params, response, state)
  end

  @doc "Handle an approval timeout — inject timeout feedback."
  @spec handle_timed_out(map(), term(), map()) :: {:next, :step, map()}
  def handle_timed_out(pending, reason, state) do
    %{tool: tool_name, params: params, response: response} = pending
    Logger.warning("Approval timeout for #{tool_name}: #{inspect(reason)}")

    Helpers.maybe_broadcast(state, %{
      type: :approval_timeout,
      approval_id: pending.approval_id,
      tool: tool_name
    })

    handle_timeout(tool_name, params, response, state)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp handle_rejection(tool_name, params, response, state) do
    rejection_msg = """
    USER REJECTED: Your proposed #{tool_name} was rejected by the user.

    They declined the following change:
    #{ContextBuilder.format_params_brief(params)}

    Please propose a different approach or use 'respond' to ask the user for clarification.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: rejection_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :rejected}})
      |> State.reset_failures()

    {:next, :step, state}
  end

  defp handle_timeout(tool_name, params, response, state) do
    timeout_msg = """
    APPROVAL TIMEOUT: No response received for #{tool_name}.

    The user did not respond to the approval request in time.
    Please use 'respond' to inform the user that approval is needed for this change.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: timeout_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :timeout}})
      |> State.reset_failures()

    {:next, :step, state}
  end
end
