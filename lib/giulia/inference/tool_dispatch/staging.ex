defmodule Giulia.Inference.ToolDispatch.Staging do
  @moduledoc """
  Transaction mode: stage writes, overlay reads, list staged files.
  Extracted from ToolDispatch in Build 114.
  """

  require Logger

  alias Giulia.Inference.{ContextBuilder, Events, State, Transaction}
  alias Giulia.Prompt.Builder

  # ============================================================================
  # Staged Execution
  # ============================================================================

  @doc "Stage a write tool call in the transaction buffer instead of writing to disk."
  def execute_staged(tool_name, params, response, state) do
    # BROADCAST
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_call,
        iteration: State.iteration(state),
        tool: tool_name,
        params: ContextBuilder.sanitize_params_for_broadcast(params),
        staged: true
      })
    end

    Logger.info("=== STAGED TOOL CALL [#{State.iteration(state)}] ===")
    Logger.info("Tool: #{tool_name} (transaction mode)")

    resolve_fn = &ContextBuilder.resolve_tool_path(&1, state)

    {result, new_tx} =
      case tool_name do
        "write_file" ->
          Transaction.stage_write(state.transaction, params, resolve_fn)

        "edit_file" ->
          Transaction.stage_edit(state.transaction, params, resolve_fn)

        tool when tool in ["patch_function", "write_function"] ->
          Transaction.stage_ast(state.transaction, tool, params,
            project_path: state.project_path,
            resolve_fn: resolve_fn,
            tool_opts: ContextBuilder.build_tool_opts(state)
          )

        _ ->
          {{:error, "Unknown stageable tool: #{tool_name}"}, state.transaction}
      end

    state = State.set_transaction(state, new_tx)

    {result_preview, observation} =
      case result do
        {:ok, msg} ->
          staged_count = map_size(state.transaction.staging_buffer)

          obs =
            "[STAGED] #{tool_name}: #{msg}\nCurrently staging #{staged_count} file(s). Use commit_changes to flush to disk."

          {String.slice(msg, 0, 200), obs}

        {:error, reason} ->
          error_str = if is_binary(reason), do: reason, else: inspect(reason)
          {"ERROR: #{error_str}", "ERROR: #{tool_name} staging failed: #{error_str}"}
      end

    Logger.info("Staged result: #{result_preview}")
    Logger.info("=== END STAGED TOOL CALL ===")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_result,
        tool: tool_name,
        success: match?({:ok, _}, result),
        preview: result_preview,
        staged: true
      })
    end

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, result})
      |> State.reset_failures()
      |> State.reset_goal_blocks()

    {:next, :step, state}
  end

  # ============================================================================
  # Read with Overlay
  # ============================================================================

  @doc "Read a file, returning staged content if it exists in the transaction buffer."
  def execute_read_with_overlay(params, response, state, execute_normal_fn) do
    path = params["path"] || params[:path] || params["file"] || params[:file]
    resolved_path = ContextBuilder.resolve_tool_path(path, state)

    case Transaction.read_with_overlay(state.transaction, resolved_path) do
      nil ->
        # Not in staging buffer — normal read
        execute_normal_fn.("read_file", params, response, state)

      staged_content ->
        Logger.info("READ OVERLAY: Returning staged content for #{path}")

        result = {:ok, "[STAGED VERSION — not yet on disk]\n#{staged_content}"}

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: State.iteration(state),
            tool: "read_file",
            params: ContextBuilder.sanitize_params_for_broadcast(params),
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "read_file",
            success: true,
            preview: "[STAGED] #{String.slice(staged_content, 0, 100)}",
            staged: true
          })
        end

        assistant_msg =
          response.content || Jason.encode!(%{tool: "read_file", parameters: params})

        observation = Builder.format_observation("read_file", result)

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_messages(messages)
          |> State.record_action({"read_file", params, result})
          |> State.reset_failures()

        {:next, :step, state}
    end
  end

  # ============================================================================
  # Get Staged Files
  # ============================================================================

  @doc "List all files currently in the transaction staging buffer."
  def execute_get_staged_files(response, state) do
    result = {:ok, Transaction.format_staged_files(state.transaction)}

    assistant_msg =
      response.content || Jason.encode!(%{tool: "get_staged_files", parameters: %{}})

    observation = Giulia.Prompt.Builder.format_observation("get_staged_files", result)

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({"get_staged_files", %{}, :ok})
      |> State.reset_failures()

    {:next, :step, state}
  end
end
