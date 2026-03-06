defmodule Giulia.Inference.ContextBuilder.Intervention do
  @moduledoc """
  Intervention messages for tool loops and failures.

  Dispatches to read-only or write intervention based on last action.
  """

  alias Giulia.Inference.ContextBuilder.Helpers
  alias Giulia.Inference.State

  @read_only_tools ~w(get_impact_map trace_path get_module_info search_code read_file
                       list_files lookup_function get_function get_context cycle_check)

  @doc "Build the main intervention message (dispatches to read-only or write variant)."
  @spec build_intervention_message(map(), String.t() | nil, String.t() | nil) :: String.t()
  def build_intervention_message(state, target_file, fresh_content) do
    case state.last_action do
      {tool_name, _params} when tool_name in @read_only_tools ->
        build_readonly_intervention(tool_name, state)

      _ ->
        build_write_intervention(state, target_file, fresh_content)
    end
  end

  @doc "Build test failure intervention."
  @spec build_test_failure_intervention(map(), map()) :: String.t()
  def build_test_failure_intervention(test_params, state) do
    test_file = test_params["file"] || test_params[:file]
    opts = Helpers.build_tool_opts(state)

    test_result =
      case Giulia.Tools.RunTests.execute(test_params, opts) do
        {:ok, result} -> result
        {:error, reason} -> "Test run failed: #{inspect(reason)}"
      end

    test_content =
      if test_file do
        project_path = state.project_path || File.cwd!()
        full_path = Path.join(project_path, test_file)

        case File.read(full_path) do
          {:ok, content} -> content
          {:error, _} -> "(could not read test file)"
        end
      else
        "(no test file specified)"
      end

    """
    INTERVENTION: You keep running tests but not fixing the failure. STOP running tests.

    TEST RESULTS:
    #{test_result}

    TEST FILE (#{test_file}):
    #{test_content}

    The test has a WRONG ASSERTION. The test input says one value but the assert checks a different value.
    You MUST use edit_file to fix the wrong assertion in the test file.

    EXAMPLE — to fix a wrong assertion:
    <action>
    {"tool": "edit_file", "parameters": {"path": "#{test_file}", "old_text": "assert result == \\"wrong_value\\"", "new_text": "assert result == \\"correct_value\\""}}
    </action>

    DO NOT run tests again. Use edit_file NOW to fix the assertion, then use respond.
    """
  end

  @doc "Build intervention for read-only tool loops."
  @spec build_readonly_intervention(String.t(), map()) :: String.t()
  def build_readonly_intervention(tool_name, state) do
    last_result =
      case state.action_history do
        [{_tool, _params, result} | _] -> inspect(result, limit: 200)
        _ -> "(no result available)"
      end

    """
    REPETITION ERROR: You called "#{tool_name}" #{State.repeat_count(state) + 1} times with the same parameters.
    The tool returned the same result each time. Repeating it will NOT change the outcome.

    Last result: #{last_result}

    You are PROHIBITED from calling #{tool_name} again with those parameters.
    You MUST do ONE of these instead:
    1. Use "respond" to answer the user with whatever information you have gathered
    2. Try a DIFFERENT tool (e.g., get_module_info, search_code, list_files)
    3. Try the SAME tool with DIFFERENT parameters (e.g., a shorter module name)

    Use respond NOW to give the user your analysis.
    """
  end

  @doc "Build intervention for write-tool loops."
  @spec build_write_intervention(map(), String.t() | nil, String.t() | nil) :: String.t()
  def build_write_intervention(state, target_file, fresh_content) do
    error_summary =
      state.recent_errors
      |> Enum.take(3)
      |> Enum.map(&"- #{inspect(&1)}")
      |> Enum.join("\n")

    action_summary =
      state.action_history
      |> Enum.take(3)
      |> Enum.map(fn {tool, params, _} -> "- #{tool}: #{Helpers.format_params_brief(params)}" end)
      |> Enum.join("\n")

    fresh_section =
      if target_file && fresh_content do
        """

        === CONTEXT PURGE: Fresh file content ===
        Target file: #{target_file}

        #{fresh_content}
        === END FRESH CONTENT ===

        The above is the CURRENT state of the file. Your previous attempts may have been based on stale data.
        """
      else
        ""
      end

    """
    INTERVENTION: You appear to be stuck in a loop. Your context has been PURGED.

    Recent errors:
    #{if error_summary == "", do: "(none)", else: error_summary}

    Recent actions:
    #{if action_summary == "", do: "(none)", else: action_summary}
    #{fresh_section}
    AGENTIC MANDATE: You are the developer. DO NOT ask the user to fix it.
    Use patch_function (for whole functions) or edit_file (for small fixes). Goal: GREEN BUILD.

    INSTRUCTIONS:
    1. Look at the fresh file content above (if provided)
    2. Identify the EXACT syntax error (missing end, unclosed string, etc.)
    3. For function replacement: use patch_function with code in ```elixir block after </action>
    4. For small edits: use edit_file with the EXACT old_text from the file
    5. If you cannot complete the task, use respond to explain why
    """
  end
end
