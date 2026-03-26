defmodule Giulia.Inference.ToolDispatch.Executor do
  @moduledoc """
  Core tool execution lifecycle: telemetry, Registry.execute, error recovery,
  state recording, auto read-back, and goal tracking.
  Extracted from ToolDispatch in Build 114.
  """

  require Logger

  alias Giulia.Inference.{ContextBuilder, State}
  alias Giulia.Inference.Engine.Helpers
  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.Context.Store

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # ============================================================================
  # Normal Execution
  # ============================================================================

  @doc "Execute a tool call through the normal lifecycle (telemetry, execute, record)."
  @spec execute_normal(String.t(), map(), map(), map()) :: {:next, atom() | tuple(), map()}
  def execute_normal(tool_name, params, response, state) do
    # BROADCAST: Tool call starting
    Helpers.maybe_broadcast(state, %{
      type: :tool_call,
      iteration: State.iteration(state),
      tool: tool_name,
      params: ContextBuilder.sanitize_params_for_broadcast(params)
    })

    Logger.info("=== TOOL CALL [#{State.iteration(state)}] ===")
    Logger.info("Tool: #{tool_name}")
    Logger.info("Params: #{inspect(params, pretty: true, limit: 500)}")

    # EXECUTE
    tool_opts = ContextBuilder.build_tool_opts(state)

    :telemetry.execute(
      [:giulia, :tool, :start],
      %{system_time: System.system_time(:millisecond)},
      %{tool: tool_name, params: ContextBuilder.sanitize_params_for_broadcast(params),
        iteration: State.iteration(state), request_id: state.request_id}
    )

    t0 = System.monotonic_time(:millisecond)

    result =
      try do
        Registry.execute(tool_name, params, tool_opts)
      rescue
        e in FunctionClauseError ->
          {:error,
           "Invalid parameters for #{tool_name}. Check required fields. Details: #{Exception.message(e)}"}

        e ->
          {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
      end

    duration_ms = System.monotonic_time(:millisecond) - t0

    # Log result
    result_preview =
      case result do
        {:ok, data} when is_binary(data) -> data
        {:ok, data} -> inspect(data, pretty: true, limit: :infinity)
        {:error, reason} -> "ERROR: #{inspect(reason)}"
        other -> inspect(other, limit: :infinity)
      end

    Logger.info("Result: #{result_preview}")
    Logger.info("=== END TOOL CALL ===")

    :telemetry.execute(
      [:giulia, :tool, :stop],
      %{duration_ms: duration_ms, system_time: System.system_time(:millisecond)},
      %{tool: tool_name, success: match?({:ok, _}, result),
        preview: String.slice(result_preview, 0, 200), request_id: state.request_id}
    )

    # AUTO READ-BACK
    result = maybe_inject_readback(tool_name, params, result, tool_opts)

    # BROADCAST: Tool result
    Helpers.maybe_broadcast(state, %{
      type: :tool_result,
      tool: tool_name,
      success: match?({:ok, _}, result),
      preview: result_preview
    })

    # Record in history
    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})
    messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, result})
      |> State.reset_failures()
      |> State.reset_goal_blocks()

    # TEST-LOCK: Track test results
    state =
      if tool_name == "run_tests" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            if String.contains?(result_str, "0 failures") or
                 String.starts_with?(result_str, "ALL TESTS PASSED") do
              Logger.info("TEST-LOCK: Tests are GREEN")
              State.set_test_status(state, :green)
            else
              Logger.info("TEST-LOCK: Tests are RED")
              State.set_test_status(state, :red)
            end

          _ ->
            Logger.info("TEST-LOCK: Tests are RED (error)")
            State.set_test_status(state, :red)
        end
      else
        state
      end

    # GOAL TRACKER: Capture impact_map results
    state =
      if tool_name == "get_impact_map" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            dependents = Giulia.Inference.ToolDispatch.Guards.extract_downstream_dependents(result_str)
            module = params["module"] || params[:module] || "unknown"

            if dependents != [] do
              Logger.info("GOAL TRACKER: Captured #{length(dependents)} dependents for #{module}")

              State.set_impact_map(state, %{
                module: module,
                dependents: dependents,
                count: length(dependents)
              })
            else
              state
            end

          _ ->
            state
        end
      else
        state
      end

    # GOAL TRACKER: Track modified files
    state =
      if tool_name in @write_tools do
        path = params["path"] || params[:path] || params["file"] || params[:file]

        if path do
          resolved = ContextBuilder.resolve_tool_path(path, state)
          State.track_modified_file(state, resolved)
        else
          state
        end
      else
        state
      end

    # VERIFY: Auto-compile after write operations
    if tool_name in @write_tools do
      {:next, {:verify, tool_name, result}, State.set_pending_verification(state, true)}
    else
      # OBSERVE: Feed result back
      observation = Builder.format_observation(tool_name, result)
      messages = state.messages ++ [%{role: "user", content: observation}]
      {:next, :step, State.set_messages(state, messages)}
    end
  end

  # ============================================================================
  # Auto Read-Back on Tool Failure
  # ============================================================================

  @doc false
  @spec maybe_inject_readback(String.t(), map(), {:ok, term()} | {:error, term()}, keyword()) ::
          {:ok, term()} | {:error, term()}
  def maybe_inject_readback(tool_name, params, {:error, reason} = original_error, tool_opts)
      when tool_name in ["edit_file", "write_function", "patch_function"] do
    project_path = Keyword.get(tool_opts, :project_path)
    file_path = get_file_path_from_params(tool_name, params, project_path)

    if file_path do
      case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
        {:ok, file_content} ->
          truncated =
            if String.length(file_content) > 2000 do
              String.slice(file_content, 0, 2000) <>
                "\n\n... [truncated, #{String.length(file_content)} bytes total]"
            else
              file_content
            end

          enhanced_error = """
          #{reason}

          === AUTO READ-BACK: Current file content ===
          #{truncated}
          === END READ-BACK ===

          Use this content to construct a correct edit_file call.
          """

          Logger.info("Auto Read-Back injected for #{file_path}")
          {:error, enhanced_error}

        {:error, read_error} ->
          Logger.warning("Auto Read-Back failed: #{inspect(read_error)}")
          original_error
      end
    else
      original_error
    end
  end

  def maybe_inject_readback(_tool_name, _params, result, _tool_opts), do: result

  # ============================================================================
  # File Path Resolution Helpers
  # ============================================================================

  defp get_file_path_from_params("edit_file", params, _project_path) do
    params["file"] || params[:file]
  end

  defp get_file_path_from_params("write_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params("patch_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params(_tool, _params, _project_path), do: nil

  defp lookup_module_file(nil, _project_path), do: nil

  defp lookup_module_file(module_name, project_path) do
    case Store.Query.find_module(project_path, module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end
end
