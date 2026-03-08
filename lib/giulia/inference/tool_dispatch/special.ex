defmodule Giulia.Inference.ToolDispatch.Special do
  @moduledoc """
  Special tool interceptors: bulk_replace, rename_mfa, commit_changes.
  Extracted from ToolDispatch in Build 114.
  """

  require Logger

  alias Giulia.Inference.{BulkReplace, ContextBuilder, RenameMFA, State}
  alias Giulia.Inference.Engine.Helpers

  # ============================================================================
  # Bulk Replace
  # ============================================================================

  @doc "Execute a batch find-replace across multiple files via BulkReplace module."
  @spec execute_bulk_replace(map(), map(), map()) :: {:next, :step, map()}
  def execute_bulk_replace(params, response, state) do
    file_list = params["file_list"] || params[:file_list] || []

    state =
      if not state.transaction.mode and file_list != [] do
        Logger.info("BULK_REPLACE: Auto-enabling transaction mode for batch operation")

        Helpers.maybe_broadcast(state, %{
          type: :transaction_auto_enabled,
          reason: "bulk_replace across #{length(file_list)} files"
        })

        State.set_transaction(state, %{state.transaction | mode: true})
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &ContextBuilder.resolve_tool_path(&1, state),
      modified_files: state.goal.modified_files
    ]

    case BulkReplace.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        Helpers.maybe_broadcast(state, %{
          type: :tool_call,
          iteration: State.iteration(state),
          tool: "bulk_replace",
          params: %{pattern: meta.pattern, replacement: meta.replacement,
                     files: meta.file_count},
          staged: true
        })

        Helpers.maybe_broadcast(state, %{
          type: :tool_result,
          tool: "bulk_replace",
          success: meta.total_replacements > 0,
          preview: "#{length(meta.staged)} files staged, #{meta.total_replacements} replacements",
          staged: true
        })

        assistant_msg =
          response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_transaction(new_tx)
          |> put_in([Access.key(:goal), :modified_files], modified_files)
          |> State.set_messages(messages)
          |> State.record_action({"bulk_replace", params, {:ok, "staged"}})
          |> State.reset_failures()

        {:next, :step, state}

      {:error, reason} ->
        send_bulk_error(reason, params, response, state)
    end
  end

  @doc false
  def send_bulk_error(reason, params, response, state) do
    observation = "ERROR: bulk_replace failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state |> State.set_messages(messages) |> State.increment_failures()
    {:next, :step, state}
  end

  # ============================================================================
  # Rename MFA
  # ============================================================================

  @doc "Execute an AST-based module/function/arity rename via RenameMFA module."
  @spec execute_rename_mfa(map(), map(), map()) :: {:next, :step, map()}
  def execute_rename_mfa(params, response, state) do
    state =
      if not state.transaction.mode do
        module = params["module"] || params[:module]
        old_name = params["old_name"] || params[:old_name]
        arity = params["arity"] || params[:arity]
        new_name = params["new_name"] || params[:new_name]
        Logger.info("RENAME_MFA: Auto-enabling transaction mode")

        Helpers.maybe_broadcast(state, %{
          type: :transaction_auto_enabled,
          reason: "rename_mfa: #{module}.#{old_name}/#{arity} → #{new_name}"
        })

        State.set_transaction(state, %{state.transaction | mode: true})
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &ContextBuilder.resolve_tool_path(&1, state),
      modified_files: state.goal.modified_files
    ]

    case RenameMFA.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        Helpers.maybe_broadcast(state, %{
          type: :tool_call,
          iteration: State.iteration(state),
          tool: "rename_mfa",
          params: %{module: meta.module, old_name: meta.old_name,
                     new_name: meta.new_name, arity: meta.arity},
          staged: true
        })

        Helpers.maybe_broadcast(state, %{
          type: :tool_result,
          tool: "rename_mfa",
          success: meta.total_changes > 0,
          preview: "#{length(meta.staged)} files, #{meta.total_changes} renames",
          staged: true
        })

        assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = state
          |> State.set_transaction(new_tx)
          |> put_in([Access.key(:goal), :modified_files], modified_files)
          |> State.set_messages(messages)
          |> State.record_action({"rename_mfa", params, {:ok, "staged"}})
          |> State.reset_failures()

        {:next, :step, state}

      {:error, reason} ->
        send_rename_error(reason, params, response, state)
    end
  end

  @doc false
  def send_rename_error(reason, params, response, state) do
    observation = "ERROR: rename_mfa failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = state |> State.set_messages(messages) |> State.increment_failures()
    {:next, :step, state}
  end

  # ============================================================================
  # Commit Changes (Route to Engine)
  # ============================================================================

  @doc "Handle commit_changes — route to Engine if staging buffer is non-empty."
  @spec execute_commit_changes(map(), map(), map()) :: {:next, :step | {:commit_changes, map()}, map()}
  def execute_commit_changes(params, response, state) do
    if map_size(state.transaction.staging_buffer) == 0 do
      observation = "Nothing staged to commit. Use write_file or edit_file first."

      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages =
        state.messages ++
          [
            %{role: "assistant", content: assistant_msg},
            %{role: "user", content: observation}
          ]

      state = state |> State.set_messages(messages) |> State.reset_failures()
      {:next, :step, state}
    else
      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]
      state = State.set_messages(state, messages)
      {:next, {:commit_changes, params}, state}
    end
  end
end
