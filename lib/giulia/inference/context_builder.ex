defmodule Giulia.Inference.ContextBuilder do
  @moduledoc """
  All message/prompt construction, previews, interventions, and hub risk assessment.

  Mostly pure functions (some File.read for previews).
  Extracted from Orchestrator in build 84.
  """

  require Logger

  alias Giulia.Context.Store
  alias Giulia.Core.{PathMapper, PathSandbox}
  alias Giulia.Inference.State
  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.Utils.Diff

  @read_only_tools ~w(get_impact_map trace_path get_module_info search_code read_file
                       list_files lookup_function get_function get_context cycle_check)

  # ============================================================================
  # Message Construction
  # ============================================================================

  @doc "Build the initial message list for a new inference."
  def build_initial_messages(prompt, state, provider_module) do
    constitution = get_constitution(state.project_pid)
    minimal = provider_module == Giulia.Provider.LMStudio

    project_summary = Store.project_summary(state.project_path)
    cwd = get_working_directory(state)

    opts = [
      constitution: constitution,
      minimal: minimal,
      project_summary: project_summary,
      cwd: cwd,
      transaction_mode: state.transaction.mode,
      staged_files: Map.keys(state.transaction.staging_buffer)
    ]

    briefing_opt =
      case Giulia.Intelligence.SurgicalBriefing.build(prompt, state.project_path) do
        {:ok, briefing} -> [surgical_briefing: briefing]
        :skip -> []
      end

    Builder.build_messages(prompt, opts ++ briefing_opt)
  end

  @doc "Inject distilled context into messages (after first iteration)."
  def inject_distilled_context(messages, state) do
    if state.action_history == [] do
      messages
    else
      context = build_context_reminder(state)

      case List.last(messages) do
        %{role: "user", content: content} ->
          List.replace_at(messages, -1, %{role: "user", content: content <> "\n\n" <> context})

        _ ->
          messages ++ [%{role: "user", content: context}]
      end
    end
  end

  @doc "Build the context reminder string."
  def build_context_reminder(state) do
    recent_actions =
      state.action_history
      |> Enum.take(3)
      |> Enum.map(fn {tool, params, result} ->
        status =
          case result do
            {:ok, _} -> "OK"
            {:error, _} -> "FAILED"
            :ok -> "OK"
            _ -> "?"
          end

        "- #{tool}(#{format_params_brief(params)}) -> #{status}"
      end)
      |> Enum.join("\n")

    modules_count = length(Store.list_modules(state.project_path))

    """
    [CONTEXT REMINDER]
    Iteration: #{State.iteration(state)}/#{State.max_iterations(state)}
    Indexed modules: #{modules_count}
    Recent actions:
    #{recent_actions}
    """
  end

  # ============================================================================
  # Intervention Messages
  # ============================================================================

  @doc "Build the main intervention message (dispatches to read-only or write variant)."
  def build_intervention_message(state, target_file, fresh_content) do
    case state.last_action do
      {tool_name, _params} when tool_name in @read_only_tools ->
        build_readonly_intervention(tool_name, state)

      _ ->
        build_write_intervention(state, target_file, fresh_content)
    end
  end

  @doc "Build test failure intervention."
  def build_test_failure_intervention(test_params, state) do
    test_file = test_params["file"] || test_params[:file]
    opts = build_tool_opts(state)

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
  def build_write_intervention(state, target_file, fresh_content) do
    error_summary =
      state.recent_errors
      |> Enum.take(3)
      |> Enum.map(&"- #{inspect(&1)}")
      |> Enum.join("\n")

    action_summary =
      state.action_history
      |> Enum.take(3)
      |> Enum.map(fn {tool, params, _} -> "- #{tool}: #{format_params_brief(params)}" end)
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

  # ============================================================================
  # Test Hints & Observations
  # ============================================================================

  @doc "Build test hints for BUILD GREEN observations."
  def build_test_hint(state) do
    target_file = extract_target_file(state)
    direct_hint = build_direct_test_hint(target_file, state)
    regression_hint = build_regression_hint(state)

    case {direct_hint, regression_hint} do
      {"", ""} -> ""
      {d, ""} -> d
      {"", r} -> r
      {d, r} -> d <> r
    end
  end

  defp build_direct_test_hint(nil, _state), do: ""

  defp build_direct_test_hint(target_file, state) do
    test_path = Giulia.Tools.RunTests.suggest_test_file(target_file)

    resolved =
      if state.project_path do
        sandbox = PathSandbox.new(state.project_path)

        case PathSandbox.validate(sandbox, test_path) do
          {:ok, resolved} -> resolved
          {:error, _} -> nil
        end
      end

    if resolved && File.exists?(resolved) do
      "Note: Tests exist at #{test_path}. You may run them with run_tests to verify behavior.\n"
    else
      ""
    end
  end

  @doc "Build graph-driven regression hint."
  def build_regression_hint(state) do
    case state.last_action do
      {tool_name, params}
      when tool_name in ["patch_function", "write_function", "edit_file", "write_file"] ->
        module_name = resolve_module_from_params(tool_name, params, state.project_path)

        if module_name do
          case Giulia.Knowledge.Store.centrality(state.project_path, module_name) do
            {:ok, %{in_degree: in_degree, dependents: dependents}} when in_degree > 3 ->
              top_3 = Enum.take(dependents, 3)

              "HUB IMPACT: #{module_name} has #{in_degree} dependents. Consider running tests for: #{Enum.join(top_3, ", ")}\n"

            _ ->
              ""
          end
        else
          ""
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  # ============================================================================
  # File Extraction Helpers
  # ============================================================================

  @doc "Extract the target file from state (task description + action history)."
  def extract_target_file(state) do
    task_file = extract_file_from_text(state.task)

    action_file =
      state.action_history
      |> Enum.find_value(fn
        {tool, params, _}
        when tool in ["read_file", "edit_file", "write_file", "write_function", "patch_function"] ->
          params["file"] || params["path"] || params[:file] || params[:path] ||
            lookup_module_file(params["module"] || params[:module], state.project_path)

        {_, _, _} ->
          nil
      end)

    task_file || action_file
  end

  defp lookup_module_file(nil, _project_path), do: nil

  defp lookup_module_file(module_name, project_path) do
    case Store.find_module(project_path, module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end

  defp extract_file_from_text(text) do
    case Regex.run(~r/(?:lib|test)\/[\w\/]+\.(?:ex|exs)/, text) do
      [match] -> match
      nil -> nil
    end
  end

  @doc "Read fresh content for a file path (uses Registry for sandbox)."
  def read_fresh_content(file_path, state) do
    tool_opts = build_tool_opts(state)

    case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
      {:ok, content} ->
        if String.length(content) > 3000 do
          String.slice(content, 0, 3000) <> "\n\n... [truncated]"
        else
          content
        end

      {:error, _} ->
        nil
    end
  end

  # ============================================================================
  # Approval Previews
  # ============================================================================

  @doc "Generate a preview for the approval request."
  def generate_preview(tool_name, params, state) do
    case tool_name do
      "write_file" ->
        generate_write_preview(params, state)

      "edit_file" ->
        generate_edit_preview(params, state)

      "write_function" ->
        generate_function_preview(params, state)

      "patch_function" ->
        generate_function_preview(params, state)

      "run_tests" ->
        file = params["file"] || params[:file]
        test_name = params["test_name"] || params[:test_name]

        cond do
          file && test_name -> "Run tests in #{file} matching '#{test_name}'"
          file -> "Run tests in #{file}"
          test_name -> "Run all tests matching '#{test_name}'"
          true -> "Run ALL project tests"
        end

      _ ->
        "Tool: #{tool_name}\nParams: #{inspect(params, pretty: true, limit: 500)}"
    end
  end

  @doc "Generate write preview (diff for existing, preview for new)."
  def generate_write_preview(params, state) do
    path = params["path"] || params[:path]
    content = params["content"] || params[:content] || ""

    resolved_path = resolve_tool_path(path, state)

    case File.read(resolved_path) do
      {:ok, existing_content} ->
        Diff.colorized(existing_content, content, file_path: path)

      {:error, :enoent} ->
        Diff.preview_new(content, file_path: path)

      {:error, _} ->
        Diff.preview_new(content, file_path: path)
    end
  end

  @doc "Generate edit preview (context diff)."
  def generate_edit_preview(params, state) do
    file = params["file"] || params[:file] || params["path"] || params[:path]
    old_text = params["old_text"] || params[:old_text] || ""
    new_text = params["new_text"] || params[:new_text] || ""

    resolved_path = resolve_tool_path(file, state)

    case File.read(resolved_path) do
      {:ok, content} ->
        if String.contains?(content, old_text) do
          new_content = String.replace(content, old_text, new_text, global: false)
          Diff.colorized(content, new_content, file_path: file)
        else
          "File: #{file}\n\nold_text not found in file:\n#{String.slice(old_text, 0, 200)}"
        end

      {:error, _} ->
        "File: #{file}\n\nCould not read file to generate preview."
    end
  end

  @doc "Generate function preview (patch/write_function diff)."
  def generate_function_preview(params, state) do
    module = params["module"] || params[:module]
    func_name = params["function_name"] || params[:function_name]
    arity = params["arity"] || params[:arity]
    new_code = params["code"] || params[:code] || ""

    case Store.find_module(state.project_path, module) do
      {:ok, %{file: file_path}} ->
        resolved = resolve_tool_path(file_path, state)

        case File.read(resolved) do
          {:ok, content} ->
            old_code = extract_old_function(content, func_name, arity)

            if old_code do
              diff = Diff.colorized(old_code, new_code, file_path: Path.basename(file_path))

              """
              Module: #{module}
              Function: #{func_name}/#{arity}
              File: #{Path.basename(file_path)}

              #{diff}
              """
            else
              """
              Module: #{module}
              Function: #{func_name}/#{arity} (new)
              File: #{Path.basename(file_path)}

              === NEW FUNCTION CODE ===
              #{new_code}
              """
            end

          {:error, _} ->
            "Module: #{module}\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
        end

      :not_found ->
        "Module: #{module} (not found in index)\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
    end
  end

  # ============================================================================
  # Hub Risk Assessment
  # ============================================================================

  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  @doc "Assess hub risk for a write tool. Returns warning string or nil."
  def assess_hub_risk(tool_name, params, project_path)
      when tool_name in @write_tools do
    module_name = resolve_module_from_params(tool_name, params, project_path)

    if module_name do
      case Giulia.Knowledge.Store.centrality(project_path, module_name) do
        {:ok, %{in_degree: in_degree, dependents: dependents}} when in_degree > 3 ->
          top_dependents = Enum.take(dependents, 3) |> Enum.join(", ")

          """
          ⚠️  CRITICAL HUB WARNING ⚠️
          You are modifying #{module_name}. This module is a Hub with #{in_degree} dependents.
          A mistake here will break: #{top_dependents}#{if in_degree > 3, do: " (+#{in_degree - 3} more)", else: ""}
          Suggested regression: run tests for #{top_dependents}
          """

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def assess_hub_risk(_tool_name, _params, _project_path), do: nil

  @doc "Resolve the module name from tool params."
  def resolve_module_from_params("edit_file", params, project_path) do
    file = params["file"] || params[:file]
    module_from_file_path(file, project_path)
  end

  def resolve_module_from_params("write_file", params, project_path) do
    path = params["path"] || params[:path]
    module_from_file_path(path, project_path)
  end

  def resolve_module_from_params(tool_name, params, _project_path)
      when tool_name in ["patch_function", "write_function"] do
    params["module"] || params[:module]
  end

  def resolve_module_from_params(_, _, _project_path), do: nil

  defp module_from_file_path(nil, _project_path), do: nil

  defp module_from_file_path(path, project_path) do
    case Store.find_module_by_file(project_path, path) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end

  # ============================================================================
  # Shared Utilities
  # ============================================================================

  @doc "Format params as a brief string."
  def format_params_brief(params) when is_map(params) do
    params
    |> Enum.take(2)
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v), do: String.slice(v, 0, 20), else: inspect(v)
      "#{k}: #{v_str}"
    end)
    |> Enum.join(", ")
  end

  @doc "Sanitize params for broadcasting (truncate large content)."
  def sanitize_params_for_broadcast(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} ->
      if is_binary(v) and byte_size(v) > 500 do
        {k, String.slice(v, 0, 500) <> "... (truncated)"}
      else
        {k, v}
      end
    end)
    |> Map.new()
  end

  def sanitize_params_for_broadcast(params), do: params

  @doc "Resolve a tool path through the sandbox."
  def resolve_tool_path(nil, _state), do: nil

  def resolve_tool_path(path, state) do
    if state.project_path do
      sandbox = PathSandbox.new(state.project_path)

      case PathSandbox.validate(sandbox, path) do
        {:ok, resolved} -> resolved
        {:error, _} -> path
      end
    else
      path
    end
  end

  @doc "Build standard tool opts from state."
  def build_tool_opts(state) do
    opts = []

    opts =
      if state.project_path do
        Keyword.put(opts, :project_path, state.project_path)
      else
        opts
      end

    opts =
      if state.project_pid do
        Keyword.put(opts, :project_pid, state.project_pid)
      else
        opts
      end

    opts =
      if state.project_path do
        sandbox = PathSandbox.new(state.project_path)
        Keyword.put(opts, :sandbox, sandbox)
      else
        opts
      end

    opts
  end

  @doc "Get working directory for display."
  def get_working_directory(state) do
    if state.project_path do
      PathMapper.to_host(state.project_path)
    else
      File.cwd!()
    end
  end

  @doc "Count recent consecutive think calls."
  def count_recent_thinks(action_history) do
    action_history
    |> Enum.take_while(fn {tool, _, _} -> tool == "think" end)
    |> length()
  end

  # ============================================================================
  # Private Helpers (Function Extraction for Previews)
  # ============================================================================

  defp get_constitution(nil), do: nil

  defp get_constitution(pid) when is_pid(pid) do
    try do
      Giulia.Core.ProjectContext.get_constitution(pid)
    catch
      :exit, _ -> nil
    end
  end

  defp extract_old_function(content, func_name, arity) do
    source = String.replace(content, "\r\n", "\n")
    func_atom = String.to_atom(func_name)
    arity = if is_binary(arity), do: String.to_integer(arity), else: arity

    case Sourceror.parse_string(source) do
      {:ok, {:defmodule, _meta, [_alias, [do: body]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      {:ok, {:defmodule, _meta, [_alias, [{_do_key, body}]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_function_from_body(source, {:__block__, _meta, statements}, func_atom, arity) do
    ranges =
      Enum.flat_map(statements, fn stmt ->
        case match_func_def(stmt, func_atom, arity) do
          {:ok, range} -> [range]
          _ -> []
        end
      end)

    case ranges do
      [] ->
        nil

      [first | _] ->
        last = List.last(ranges)
        lines = String.split(source, "\n")
        end_line = min(last.end_line || length(lines), length(lines))

        lines
        |> Enum.slice((first.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")
    end
  end

  defp extract_function_from_body(source, stmt, func_atom, arity) do
    case match_func_def(stmt, func_atom, arity) do
      {:ok, range} ->
        lines = String.split(source, "\n")
        end_line = min(range.end_line || length(lines), length(lines))

        lines
        |> Enum.slice((range.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  defp match_func_def({def_type, meta, [{:when, _, [{name, _, args} | _]} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def({def_type, meta, [{name, _, args} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def(_, _, _), do: :no_match
end
