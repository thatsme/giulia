defmodule Giulia.Inference.ToolDispatch.Guards do
  @moduledoc """
  Preflight checks, loop detection, guard clauses, and approval policy.
  Extracted from ToolDispatch in Build 114.
  """

  require Logger

  alias Giulia.Inference.{ContextBuilder, State, Transaction}

  # Subset of write tools that are staged when transaction_mode is active
  @stageable_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Read-only tools that never modify code
  @read_only_tools ~w(get_impact_map trace_path get_module_info search_code read_file
                       list_files lookup_function get_function get_context cycle_check)

  # ============================================================================
  # Edit-After-Patch Guard
  # ============================================================================

  @doc "Returns true if edit_file is attempted right after a failed patch_function."
  @spec edit_file_after_patch_failure?(String.t(), map()) :: boolean()
  def edit_file_after_patch_failure?("edit_file", %{
        action_history: [{last_tool, _, {:error, _}} | _]
      })
      when last_tool in ["patch_function", "write_function"] do
    true
  end

  def edit_file_after_patch_failure?(_, _), do: false

  @doc "Handle a blocked edit_file attempt with guidance to use read_file + patch_function."
  @spec handle_blocked_edit_file(map(), map(), map()) :: {:next, :step, map()}
  def handle_blocked_edit_file(params, response, state) do
    _file = params["file"] || params["path"] || "the target file"
    Logger.warning("BLOCKED: edit_file after patch_function failure — forcing read_file reset")

    error_msg = """
    BLOCKED: You cannot use edit_file right after patch_function failed.
    The file has NOT been modified (patch_function is atomic — it aborts on error).

    Your code had a syntax error. To fix it:
    1. Use read_file to see the CURRENT (unchanged) file
    2. Fix the syntax error in your code
    3. Use patch_function again with corrected code

    Do NOT use edit_file — use patch_function for function replacement.
    """

    assistant_msg = response.content || ""

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({"edit_file", params, {:error, :blocked_after_patch}})

    {:next, :step, state}
  end

  # ============================================================================
  # Preflight Check
  # ============================================================================

  @doc "Validate tool parameters before execution."
  @spec preflight_check(String.t(), map()) :: :ok | {:error, :missing_code}
  def preflight_check(tool_name, params)
      when tool_name in ["patch_function", "write_function"] do
    code = params["code"] || params[:code]

    if code && String.trim(code) != "" do
      :ok
    else
      {:error, :missing_code}
    end
  end

  def preflight_check(_tool_name, _params), do: :ok

  @doc "Handle a preflight failure with detailed error guidance."
  @spec handle_preflight_failure(String.t(), map(), atom(), map(), map()) :: {:next, :step, map()}
  def handle_preflight_failure(tool_name, params, :missing_code, response, state) do
    func_name = params["function_name"] || "func"
    module = params["module"] || "Module"
    arity = params["arity"] || 0

    error_msg = """
    TOOL CALL REJECTED: #{tool_name} requires code but you didn't provide any.

    You sent <action> but NO CODE after </action>. This will always fail.
    You MUST place the new function code in a ```elixir fenced block after </action>.

    CORRECT FORMAT:
    <action>
    {"tool": "#{tool_name}", "parameters": {"module": "#{module}", "function_name": "#{func_name}", "arity": #{arity}}}
    </action>

    ```elixir
    def #{func_name}(...) do
      # your new code here
    end
    ```

    The code goes in a ```elixir block after </action>, NOT inside JSON.
    Do NOT add any text after the closing ```. Try again.
    """

    assistant_msg = response.content || ""

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = state
      |> State.set_messages(messages)
      |> State.record_action({tool_name, params, {:error, :missing_code}})
      |> State.increment_failures()

    {:next, :step, state}
  end

  # ============================================================================
  # Approval Policy
  # ============================================================================

  @doc "Determine if a tool call requires user approval."
  @spec requires_approval?(String.t(), map(), map()) :: boolean()
  def requires_approval?("run_mix", params, _state) do
    command = params["command"] || params[:command] || ""
    command not in ["compile", "help"]
  end

  def requires_approval?("run_tests", _params, _state), do: false

  def requires_approval?(tool_name, _params, _state) do
    tool_name in @write_tools
  end

  # ============================================================================
  # Auto-Enable Transaction for Hub Modules
  # ============================================================================

  @doc "Auto-enable transaction mode when modifying hub modules."
  @spec maybe_auto_enable_transaction(String.t(), map(), map()) :: map()
  def maybe_auto_enable_transaction(tool_name, params, state)
      when tool_name in @stageable_tools do
    {new_tx, new_max} =
      Transaction.maybe_auto_enable(state.transaction, params,
        tool_name: tool_name,
        project_path: state.project_path,
        resolve_module_fn: &ContextBuilder.resolve_module_from_params/3,
        request_id: state.request_id
      )

    state = State.set_transaction(state, new_tx)

    if new_max do
      State.set_max_iterations(state, max(State.max_iterations(state), new_max))
    else
      state
    end
  end

  def maybe_auto_enable_transaction(_tool_name, _params, state), do: state

  # ============================================================================
  # Loop Detection
  # ============================================================================

  @doc "Handle a detected tool loop — heuristic completion for reads, intervention for writes."
  @spec handle_loop(String.t(), map()) :: {:next, :intervene, map()} | {:done, {:ok, String.t()}, map()}
  def handle_loop(tool_name, state) do
    Logger.warning("Same action repeated #{State.repeat_count(state)}x")

    if tool_name in @read_only_tools do
      Logger.warning(
        "HEURISTIC COMPLETION: Read-only tool loop on #{tool_name}, delivering result directly"
      )

      last_observation = find_last_successful_observation(state)

      if last_observation do
        heuristic_response = """
        #{last_observation}

        ---
        _Task completed via Heuristic Completion. The model retrieved this data but entered a response loop. \
        The Orchestrator is delivering the result directly._
        """

        {:done, {:ok, heuristic_response}, state}
      else
        {:next, :intervene, state}
      end
    else
      Logger.warning("Write-tool loop — intervening with context purge")
      {:next, :intervene, state}
    end
  end

  @doc "Find the best successful tool observation (longest) from action_history."
  @spec find_last_successful_observation(map()) :: String.t() | nil
  def find_last_successful_observation(state) do
    state.action_history
    |> Enum.flat_map(fn
      {_tool, _params, {:ok, data}} when is_binary(data) and data != "" -> [data]
      _ -> []
    end)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  # ============================================================================
  # Goal Tracker Helpers
  # ============================================================================

  @doc "Extract downstream dependent module names from impact map output text."
  @spec extract_downstream_dependents(String.t()) :: [String.t()]
  def extract_downstream_dependents(result_str) do
    case String.split(result_str, "DOWNSTREAM (what depends on me):") do
      [_, downstream_section] ->
        downstream_only =
          case String.split(downstream_section, ~r/\nFUNCTIONS[:\s]/i, parts: 2) do
            [before, _] -> before
            [all] -> all
          end

        downstream_only
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("- ")
          |> String.split(" (")
          |> List.first()
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == "" or &1 == "(none — nothing depends on this)"))

      _ ->
        []
    end
  end

  @doc "Convert a module name to a path fragment for fuzzy matching."
  @spec module_to_path(String.t()) :: String.t()
  def module_to_path(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
