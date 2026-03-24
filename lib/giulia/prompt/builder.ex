defmodule Giulia.Prompt.Builder do
  @moduledoc """
  Prompt Construction for Tool-Calling Models.

  Since we're not using InstructorEx (no NIFs!), small models (Qwen 3B)
  need very strict system prompts to ensure they return valid JSON.

  The key insight: A 3B model CAN do tool calling if you:
  1. Give it a rigid structure
  2. Show examples
  3. Inject context from ETS (not raw files)

  This is where Giulia starts "killing her father" - we don't dump
  whole files like Claude Code. We inject distilled metadata.
  """

  alias Giulia.Tools.Registry
  alias Giulia.Context.Store

  @type message :: %{role: String.t(), content: String.t()}
  @type model_tier :: :small | :medium | :large

  @doc """
  Detect model size tier from the LM Studio model name.

  Priority:
  1. Query LM Studio /v1/models for the ACTUAL loaded model (cached in app env)
  2. Fall back to GIULIA_LM_STUDIO_MODEL env var
  3. Default to :medium

  Tiers:
  - :small  (<=7B)  — ultra-constrained, one step at a time
  - :medium (8-16B) — workflow hints, edit_file examples
  - :large  (>=17B) — fuller instructions, can plan multi-step
  """
  @spec detect_model_tier() :: model_tier()
  def detect_model_tier do
    # Check cache first (avoid hitting LM Studio on every iteration)
    case Application.get_env(:giulia, :detected_model_tier) do
      nil ->
        {tier, model_name} = detect_model_from_lm_studio()
        Application.put_env(:giulia, :detected_model_tier, tier)
        Application.put_env(:giulia, :detected_model_name, model_name)
        require Logger
        Logger.info("MODEL TIER DETECTION: #{model_name} → #{tier}")
        tier

      cached_tier ->
        cached_tier
    end
  end

  @doc """
  Query LM Studio /v1/models to discover the actual loaded model.
  Returns {tier, model_name}.
  """
  @spec detect_model_from_lm_studio() :: {model_tier(), String.t()}
  def detect_model_from_lm_studio do
    url = Giulia.Core.PathMapper.lm_studio_models_url()

    case Req.get(url, receive_timeout: 3000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) and models != [] ->
        # Prefer the model matching GIULIA_LM_STUDIO_MODEL env var
        # (LM Studio can have multiple models loaded simultaneously)
        env_model = System.get_env("GIULIA_LM_STUDIO_MODEL")
        model_ids = Enum.map(models, &Map.get(&1, "id", "unknown"))

        model_id =
          if env_model do
            # Find model matching env var (partial match: "qwen/qwen2.5-coder-14b" matches "qwen2.5-coder-14b")
            env_lower = String.downcase(env_model)

            Enum.find(model_ids, List.first(model_ids), fn id ->
              id_lower = String.downcase(id)
              String.contains?(id_lower, env_lower) or String.contains?(env_lower, id_lower)
            end)
          else
            List.first(model_ids)
          end

        {detect_model_tier(model_id), model_id}

      _ ->
        # Can't reach LM Studio, fall back to env var
        model_name =
          System.get_env("GIULIA_LM_STUDIO_MODEL") ||
            Application.get_env(:giulia, :lm_studio_model, "unknown")

        {detect_model_tier(model_name), model_name}
    end
  rescue
    _ ->
      model_name = System.get_env("GIULIA_LM_STUDIO_MODEL") || "unknown"
      {detect_model_tier(model_name), model_name}
  end

  @doc """
  Clear the cached model tier (call when model changes, e.g. on new inference).
  """
  @spec clear_model_tier_cache() :: :ok
  def clear_model_tier_cache do
    Application.delete_env(:giulia, :detected_model_tier)
    Application.delete_env(:giulia, :detected_model_name)
    :ok
  end

  @spec detect_model_tier(String.t()) :: model_tier()
  def detect_model_tier(model_name) when is_binary(model_name) do
    # Extract parameter count from model name (e.g., "14b", "3b", "24b", "32b")
    case Regex.run(~r/(\d+)b/i, String.downcase(model_name)) do
      [_, size_str] ->
        {size, _} = Integer.parse(size_str)

        cond do
          size <= 7 -> :small
          size <= 16 -> :medium
          true -> :large
        end

      nil ->
        # Can't determine size, default to medium (safe middle ground)
        :medium
    end
  end

  def detect_model_tier(_), do: :medium

  # ============================================================================
  # System Prompt Generation
  # ============================================================================

  @doc """
  Build the system prompt with tool definitions and project context.

  This is the "Constitution" that constrains the model's responses.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ []) do
    tools = Registry.list_tools()
    project_summary = opts[:project_summary] || Store.Formatter.project_summary(opts[:project_path])
    constitution = opts[:constitution]

    """
    You are Giulia, an AI development agent. You work within a sandboxed project.

    ## CRITICAL: Response Format
    You MUST respond with a JSON object. No explanations, no markdown, no prose.
    If you need to explain something, use the "respond" tool.

    ## Available Tools
    #{format_tools_for_prompt(tools)}

    ## Current Project Context
    #{project_summary}

    #{build_topology_summary(opts[:project_path])}

    #{format_constitution(constitution)}

    ## Response Schema
    Your response MUST be valid JSON matching ONE of these formats:

    1. Tool Call (non-code tools):
    {"tool": "tool_name", "parameters": {"param1": "value1"}}

    2. Final Response (when task is complete):
    {"tool": "respond", "parameters": {"message": "Your response here"}}

    3. Thinking (if you need to reason):
    {"tool": "think", "parameters": {"thought": "reasoning here"}}

    4. CODE TOOLS (patch_function, write_function — code in fenced block):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Giulia.Example", "function_name": "my_func", "arity": 2}}
    </action>

    ```elixir
    def my_func(arg1, arg2) do
      # raw Elixir code — no JSON escaping needed
      arg1 + arg2
    end
    ```

    For code tools, place the new function in a ```elixir fenced block after </action>.
    The code is NOT inside JSON. Do NOT add any text after the closing ```.

    ## Examples

    User: "What's in lib/giulia/client.ex?"
    Response: {"tool": "read_file", "parameters": {"path": "lib/giulia/client.ex"}}

    User: "Analyze the try_repair_json function"
    Response: {"tool": "lookup_function", "parameters": {"function_name": "try_repair_json"}}

    After lookup returns the code:
    Response: {"tool": "respond", "parameters": {"message": "The try_repair_json function does X..."}}

    User: "Explain Module.some_func/2"
    Response: {"tool": "lookup_function", "parameters": {"function_name": "some_func", "module": "Module", "arity": 2}}

    User: "Fix the parse_response function in Giulia.StructuredOutput"
    Response (code in fenced block after action):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Giulia.StructuredOutput", "function_name": "parse_response", "arity": 1}}
    </action>

    ```elixir
    def parse_response(raw) do
      case extract_json(raw) do
        {:ok, json} -> Jason.decode(json)
        error -> error
      end
    end
    ```

    ## Tool Selection Guide
    - When asked about a SPECIFIC FUNCTION by name: Use "lookup_function" (fast, uses index)
    - When asked about a whole FILE: Use "read_file"
    - When searching for PATTERNS in code: Use "search_code"
    - When you need FUNCTION SOURCE but don't know the file: Use "lookup_function"
    - When REPLACING/REFACTORING a function: Use "patch_function" — code goes in ```elixir block after </action>
    - When RENAMING function calls across files: Use "edit_file" (old_text="OldName", new_text="NewName") — one file at a time
    - When making SMALL TEXT EDITS (imports, module attrs, config): Use "edit_file" (requires exact old_text match)
    - When RUNNING TESTS after code changes: Use "run_tests" (structured failure analysis)
    - When asked about CHANGE IMPACT or "what breaks if I change X": Use "get_impact_map"
    - When asked HOW modules are connected: Use "trace_path"
    - After multiple file edits, call "commit_changes" to atomically verify all changes

    #{build_transaction_section(opts[:transaction_mode], opts[:staged_files])}

    ## DEFINITION OF DONE (CRITICAL)
    A task is ONLY complete when ALL of these are true:
    1. The build is green (mix compile succeeds)
    2. All relevant tests pass (run_tests returns 0 failures)
    3. You have VERIFIED the fix by running run_tests AFTER your edit
    NEVER claim success based only on a green build. If tests exist, you MUST run them.
    If run_tests showed failures, you CANNOT use respond until run_tests shows 0 failures.

    ## AUTO-REGRESSION (Graph-Targeted Testing)
    When you modify a module, Giulia automatically verifies all downstream dependents.
    After BUILD GREEN, targeted tests for the modified module AND its dependents run automatically.
    If a downstream test fails, it is YOUR responsibility to fix the regression before claiming success.
    You are an Elite Engineer — you own the blast radius of every change you make.

    ## Topological Awareness (Graph-Aware Constraints)
    You are graph-aware. The Knowledge Graph tracks every module dependency.
    - When you see a "CRITICAL HUB WARNING" in an approval, you MUST prioritize backward compatibility.
    - Do NOT change public function signatures of Hub modules (>3 dependents) without a multi-step transition plan.
    - Hub modules include: Registry, Orchestrator, PathSandbox, PathMapper, Store. Treat them as load-bearing walls.
    - Leaf modules (0-1 dependents) are safe for aggressive refactoring.
    - Use get_impact_map before modifying any module you're unsure about.

    ## Constraints
    1. ONLY use tools from the Available Tools list
    2. NEVER access files outside the project root
    3. If unsure, use read_file or search_code to gather information first
    4. If search returns "No matches found", the file/function does NOT exist in this project
    5. If you cannot find something after 2 searches, use respond to explain what you tried
    6. Dependencies (deps/) are NOT searchable - only project source files
    7. For patch_function: place code in ```elixir block after </action>, NOT inside JSON

    ## AGENTIC MANDATE (CRITICAL)
    You are an AUTONOMOUS AGENT, not a chatbot. When you encounter:
    - Syntax errors
    - Build failures
    - Broken code
    - Missing delimiters (end, }, ], etc.)

    DO NOT ask the user to fix it. DO NOT just report the problem.
    YOU ARE THE DEVELOPER. Use your tools to FIX IT:
    1. read_file to see the current state
    2. Identify the exact error (missing end, unclosed string, etc.)
    3. edit_file to make the surgical fix
    4. The Orchestrator will verify with mix compile

    Your goal is a GREEN BUILD. Do not respond until mix compile succeeds.
    """
  end

  @doc """
  Build a lighter system prompt for 3B models (shorter context = better quality).

  The Architect's insight: "Qwen 3B needs to be treated like a very fast,
  very obedient, but very forgetful intern."

  Key techniques:
  - Force <action> tags for reliable extraction
  - One action at a time
  - Brutal error feedback
  """
  @spec build_minimal_prompt(keyword()) :: String.t()
  def build_minimal_prompt(opts \\ []) do
    tools = Registry.list_tools()

    """
    You are Giulia, an autonomous AI dev agent. Respond ONLY with <action> tags.

    TOOLS: #{Enum.map_join(tools, ", ", & &1.name)}

    FORMAT — non-code tools:
    <action>
    {"tool": "TOOL_NAME", "parameters": {"PARAM": "VALUE"}}
    </action>

    FORMAT — code tools (patch_function, write_function):
    <action>
    {"tool": "patch_function", "parameters": {"module": "M", "function_name": "f", "arity": 2}}
    </action>

    ```elixir
    def f(a, b), do: a + b
    ```

    Code goes in ```elixir block AFTER </action>. NOT inside JSON.

    RULES: lookup_function for known functions. read_file for files. patch_function for code changes. edit_file for small text edits (imports, config). rename_mfa for ANY function rename. bulk_replace for text string replacements only. commit_changes after multi-file edits. run_tests to verify. respond when done.

    WORKFLOW for RENAMING a function:
    1. get_impact_map to find all dependents of the target module
    2. rename_mfa with module, old_name, new_name, arity — it handles EVERYTHING automatically (def/defp, @callback, remote calls, local calls, dynamic dispatch, all implementers and callers)
    3. commit_changes is called automatically after rename_mfa
    4. respond with summary

    WORKFLOW for TEXT replacements (imports, module references, config):
    1. get_impact_map to find affected files
    2. bulk_replace with pattern, replacement, and file_list
    3. commit_changes to verify
    4. respond with summary

    CRITICAL: rename_mfa vs bulk_replace:
    - rename_mfa = AST-aware, finds ALL function definitions, calls, callbacks. Use for renaming functions.
    - bulk_replace = string matching only, cannot find function definitions. Use for text patterns only.
    - NEVER use bulk_replace to rename a function. It will miss def/defp definitions and cause compile errors.

    rename_mfa example:
    <action>
    {"tool": "rename_mfa", "parameters": {"module": "Giulia.Tools.Registry", "old_name": "execute", "new_name": "dispatch", "arity": 3}}
    </action>

    WARNING: If you used get_impact_map and found N dependents, you MUST modify all of them before responding. The system tracks your progress and will block respond if you skip files.

    #{build_transaction_section(opts[:transaction_mode], opts[:staged_files])}
    You are autonomous — fix errors yourself. Goal: green build + green tests.
    #{format_constitution_minimal(opts[:constitution])}
    """
  end

  # ============================================================================
  # Model-Tier Prompt Dispatch
  # ============================================================================

  @doc """
  Select prompt based on model size tier.

  - :small  (<=7B)  — ultra-constrained, `build_minimal_prompt` (one action per turn)
  - :medium (8-16B) — `build_minimal_prompt` with workflow hints (current default)
  - :large  (>=17B) — `build_large_model_prompt` with planning capability
  """
  @spec build_tiered_prompt(model_tier(), keyword()) :: String.t()
  def build_tiered_prompt(:small, opts), do: build_small_model_prompt(opts)
  def build_tiered_prompt(:medium, opts), do: build_minimal_prompt(opts)
  def build_tiered_prompt(:large, opts), do: build_large_model_prompt(opts)
  def build_tiered_prompt(_, opts), do: build_minimal_prompt(opts)

  @doc """
  Ultra-constrained prompt for small models (<=7B).

  Key differences from :medium:
  - No multi-step workflow hints (model can't plan ahead)
  - Fewer examples (save context space)
  - Explicit "do ONE action per response" constraint
  """
  @spec build_small_model_prompt(keyword()) :: String.t()
  def build_small_model_prompt(opts \\ []) do
    tools = Registry.list_tools()

    """
    You are Giulia, an AI dev agent. Respond with ONE <action> tag per response.

    TOOLS: #{Enum.map_join(tools, ", ", & &1.name)}

    FORMAT:
    <action>
    {"tool": "TOOL_NAME", "parameters": {"PARAM": "VALUE"}}
    </action>

    Code tools (patch_function, write_function) — code in ```elixir block AFTER </action>.
    #{build_transaction_section(opts[:transaction_mode], opts[:staged_files])}
    ONE action per response. Fix errors yourself. respond when done.
    """
  end

  @doc """
  Extended prompt for large models (>=17B).

  Key differences from :medium:
  - Includes planning workflow for multi-file tasks
  - More tool descriptions and examples
  - Can handle multi-step reasoning
  """
  @spec build_large_model_prompt(keyword()) :: String.t()
  def build_large_model_prompt(opts \\ []) do
    tools = Registry.list_tools()

    """
    You are Giulia, an autonomous AI development agent working in an Elixir project.
    Respond ONLY with <action> tags containing JSON tool calls.

    ## Available Tools
    #{format_tools_for_prompt(tools)}

    ## Response Format

    Non-code tools:
    <action>
    {"tool": "TOOL_NAME", "parameters": {"PARAM": "VALUE"}}
    </action>

    Code tools (patch_function, write_function):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Giulia.Example", "function_name": "my_func", "arity": 2}}
    </action>

    ```elixir
    def my_func(arg1, arg2) do
      arg1 + arg2
    end
    ```

    Code goes in ```elixir block AFTER </action>. NOT inside JSON.

    ## Tool Selection
    - SPECIFIC FUNCTION by name: "lookup_function" (fast, uses index)
    - Whole FILE: "read_file"
    - PATTERNS in code: "search_code"
    - RENAMING A FUNCTION: "rename_mfa" — AST-aware, handles ALL definitions, callbacks, calls, implementers automatically
    - REPLACING a function BODY (rewriting logic): "patch_function" — code in ```elixir block
    - SMALL TEXT EDITS (imports, attrs): "edit_file" (exact old_text match)
    - TEXT PATTERNS across files: "bulk_replace" — string find-and-replace only, NOT for function renames
    - TESTS: "run_tests" after code changes
    - CHANGE IMPACT: "get_impact_map" before modifying shared modules
    - MULTI-FILE EDITS: call "commit_changes" after all edits to verify atomically

    ## Workflow for Renaming a Function (IMPORTANT)
    1. get_impact_map to identify ALL dependents of the module
    2. rename_mfa with module, old_name, new_name, arity — handles everything
    3. commit_changes is called automatically
    4. If commit fails: read the error, fix the issue, try rename_mfa again
    5. respond with summary only after green build

    ## Workflow for Text Replacements (imports, config, module references)
    1. get_impact_map to identify affected files
    2. bulk_replace with pattern, replacement, and file_list
    3. commit_changes to verify
    4. respond with summary

    WARNING: The system tracks how many dependents you found vs how many you modified. If you skip files, respond will be BLOCKED.

    #{build_transaction_section(opts[:transaction_mode], opts[:staged_files])}

    ## Constraints
    - ONLY use tools from the Available Tools list
    - NEVER access files outside the project root
    - You are autonomous — fix errors yourself, don't report them
    - Goal: green build + passing tests before responding
    #{format_constitution_minimal(opts[:constitution])}
    """
  end

  # ============================================================================
  # Message Construction
  # ============================================================================

  @doc """
  Build a chat message list for the provider.
  """
  @spec build_messages(String.t(), keyword()) :: [message()]
  def build_messages(user_prompt, opts \\ []) do
    system_prompt =
      if opts[:minimal] do
        tier = opts[:model_tier] || detect_model_tier()
        build_tiered_prompt(tier, opts)
      else
        build_system_prompt(opts)
      end

    history = opts[:history] || []

    briefing_msg =
      case opts[:surgical_briefing] do
        nil -> []
        text -> [%{role: "system", content: text}]
      end

    [
      %{role: "system", content: system_prompt}
    ] ++
      briefing_msg ++
      history ++
      [
        %{role: "user", content: user_prompt}
      ]
  end

  @doc """
  Add an observation (tool result) to the message history.
  """
  @spec add_observation([message()], String.t(), term()) :: [message()]
  def add_observation(messages, tool_name, result) do
    observation = format_observation(tool_name, result)
    messages ++ [%{role: "assistant", content: observation}]
  end

  @doc """
  Format a tool result as an observation for the model.
  """
  @spec format_observation(String.t(), term()) :: String.t()
  def format_observation(tool_name, {:ok, content}) when is_binary(content) do
    # Truncate large outputs for small models
    truncated =
      if String.length(content) > 2000 do
        String.slice(content, 0, 2000) <> "\n... [truncated]"
      else
        content
      end

    """
    Tool #{tool_name} succeeded:
    #{truncated}
    """
  end

  def format_observation(tool_name, {:ok, data}) do
    format_observation(tool_name, {:ok, inspect(data, pretty: true, limit: 50)})
  end

  def format_observation(_tool_name, {:error, :enoent}) do
    """
    ERROR: File not found. The path does NOT exist.
    Use list_files to see actual paths in the directory.
    Use search_code to find files by content.
    Do NOT guess paths - verify they exist first.
    """
  end

  def format_observation(_tool_name, {:error, :sandbox_violation}) do
    """
    ERROR: Access denied. Path is outside the project sandbox.
    You can ONLY access files within this project directory.
    Use list_files to see what's available.
    """
  end

  def format_observation(_tool_name, {:error, :missing_path_parameter}) do
    """
    ERROR: Missing required 'path' parameter.
    You MUST provide a path when calling read_file.
    Example: {"tool": "read_file", "parameters": {"path": "lib/mymodule.ex"}}
    Use list_files first to see available files.
    """
  end

  def format_observation(tool_name, {:error, reason}) do
    """
    ERROR: #{tool_name} failed: #{inspect(reason)}
    Do NOT repeat the same action. Try a different approach:
    - Use list_files to verify paths exist
    - Use search_code to find the right file
    - Use respond if you cannot complete the task
    """
  end

  # ============================================================================
  # Context Injection
  # ============================================================================

  @doc """
  Build a focused context for a specific task.

  This is the "Slice" strategy - don't dump the whole codebase,
  inject only what's relevant.
  """
  @spec build_focused_context(String.t(), keyword()) :: String.t()
  def build_focused_context(task, opts \\ []) do
    # Extract likely file/module references from the task
    mentioned_modules = extract_module_mentions(task)
    mentioned_files = extract_file_mentions(task)

    # Get relevant AST summaries
    project_path = opts[:project_path]

    relevant_asts =
      (mentioned_modules ++ mentioned_files)
      |> Enum.map(&find_relevant_ast(&1, project_path))
      |> Enum.reject(&is_nil/1)
      # Max 3 files for small models
      |> Enum.take(3)

    if relevant_asts == [] do
      # No specific context, use project summary
      opts[:project_summary] || Store.Formatter.project_summary(project_path)
    else
      format_relevant_context(relevant_asts)
    end
  end

  # ============================================================================
  # Private - Formatting
  # ============================================================================

  defp build_topology_summary(project_path) do
    try do
      case Giulia.Knowledge.Store.stats(project_path) do
        %{vertices: 0} ->
          ""

        %{vertices: v, edges: e, components: c, hubs: hubs} ->
          hub_list =
            hubs
            |> Enum.take(3)
            |> Enum.map_join(", ", fn {name, degree} -> "#{name} (#{degree} deps)" end)

          """
          ## Project Topology
          Modules: #{v} vertices, Dependencies: #{e} edges, Components: #{c}
          Key hubs: #{hub_list}
          """
      end
    rescue
      _ -> ""
    catch
      _, _ -> ""
    end
  end

  defp format_tools_for_prompt(tools) do
    tools
    |> Enum.map(fn tool ->
      params = format_parameters(tool.parameters)
      "- #{tool.name}: #{tool.description}\n  Parameters: #{params}"
    end)
    |> Enum.join("\n")
  end

  defp format_parameters(%{properties: props, required: required}) do
    props
    |> Enum.map(fn {name, spec} ->
      req = if name in (required || []), do: " (required)", else: ""
      "#{name}#{req}: #{spec[:description] || spec["description"] || "no description"}"
    end)
    |> Enum.join(", ")
  end

  defp format_parameters(_), do: "none"

  defp build_transaction_section(true, staged_files)
       when is_list(staged_files) and staged_files != [] do
    file_list = Enum.map_join(staged_files, "\n", &"  - #{&1}")

    """
    ## TRANSACTION MODE (Active)
    Your writes are being STAGED, not written to disk.
    - write_file, edit_file, patch_function, write_function → buffer only
    - bulk_replace → batch find-and-replace across multiple files (all staged)
    - read_file → returns staged content if available
    - commit_changes → atomically flush all changes, compile, test, rollback on failure
    - You MUST call commit_changes before respond

    Currently staged files:
    #{file_list}
    """
  end

  defp build_transaction_section(true, _) do
    """
    ## TRANSACTION MODE (Active)
    Your writes are being STAGED, not written to disk.
    - write_file, edit_file, patch_function, write_function → buffer only
    - bulk_replace → batch find-and-replace across multiple files (all staged)
    - read_file → returns staged content if available
    - commit_changes → atomically flush all changes, compile, test, rollback on failure
    - You MUST call commit_changes before respond
    """
  end

  defp build_transaction_section(_, _), do: ""

  defp format_constitution(nil), do: ""

  defp format_constitution(%{taboos: taboos, patterns: patterns})
       when taboos != [] or patterns != [] do
    """

    ## Project Rules (from GIULIA.md)
    #{if taboos != [], do: "Taboos (NEVER do these):\n" <> Enum.map_join(taboos, "\n", &"- #{&1}"), else: ""}
    #{if patterns != [], do: "Preferred patterns:\n" <> Enum.map_join(patterns, "\n", &"- #{&1}"), else: ""}
    """
  end

  defp format_constitution(_), do: ""

  defp format_constitution_minimal(nil), do: ""

  defp format_constitution_minimal(%{taboos: [first | _]}) do
    "\nTaboo: #{first}"
  end

  defp format_constitution_minimal(_), do: ""

  defp extract_module_mentions(task) do
    # Look for CamelCase words that might be module names
    ~r/[A-Z][a-zA-Z0-9]*(?:\.[A-Z][a-zA-Z0-9]*)*/
    |> Regex.scan(task)
    |> List.flatten()
  end

  defp extract_file_mentions(task) do
    # Look for file paths
    ~r/[\w\/]+\.(?:ex|exs)/
    |> Regex.scan(task)
    |> List.flatten()
  end

  defp find_relevant_ast(module_or_file, project_path) do
    cond do
      String.contains?(module_or_file, ".") and String.contains?(module_or_file, "/") ->
        # It's a file path
        case Store.get_ast(project_path, module_or_file) do
          {:ok, ast} -> {module_or_file, ast}
          _ -> nil
        end

      String.contains?(module_or_file, ".") ->
        # It's a module name
        case Store.Query.find_module(project_path, module_or_file) do
          {:ok, %{file: file, ast_data: ast}} -> {file, ast}
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp format_relevant_context(asts) do
    asts
    |> Enum.map(fn {file, ast} ->
      functions = ast[:functions] || []
      func_list = Enum.map_join(functions, ", ", &"#{&1.name}/#{&1.arity}")
      "#{Path.basename(file)}: #{func_list}"
    end)
    |> Enum.join("\n")
  end
end
