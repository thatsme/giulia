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
    project_summary = opts[:project_summary] || Store.project_summary()
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

    #{build_topology_summary()}

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
    # Only include module names, not full summary
    modules = Store.list_modules() |> Enum.map(& &1.name) |> Enum.take(10)

    """
    You are Giulia. You MUST wrap your response in <action> tags.

    AVAILABLE TOOLS: #{Enum.map_join(tools, ", ", & &1.name)}

    PROJECT MODULES: #{Enum.join(modules, ", ")}

    RESPONSE FORMAT (REQUIRED):

    For NON-CODE tools (read, search, respond, think):
    <action>
    {"tool": "TOOL_NAME", "parameters": {"PARAM": "VALUE"}}
    </action>

    For CODE tools (patch_function, write_function):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Module.Name", "function_name": "func", "arity": 2}}
    </action>

    ```elixir
    defp func(arg1, arg2) do
      arg1 + arg2
    end
    ```

    CRITICAL: For code tools, place the code in a ```elixir fenced block after </action>.
    Do NOT put code in JSON. Do NOT add any text after the closing ```.

    EXAMPLES:

    To look up a function:
    <action>
    {"tool": "lookup_function", "parameters": {"function_name": "try_repair_json"}}
    </action>

    To read a file:
    <action>
    {"tool": "read_file", "parameters": {"path": "lib/giulia/client.ex"}}
    </action>

    To replace a function (code in fenced block):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Giulia.Example", "function_name": "hello", "arity": 1}}
    </action>

    ```elixir
    def hello(name) do
      "Hello, " <> name <> "!"
    end
    ```

    To respond:
    <action>
    {"tool": "respond", "parameters": {"message": "The function does X..."}}
    </action>

    RULES:
    1. For FUNCTION questions: Use lookup_function (fast, uses index)
    2. For FILE questions: Use read_file
    3. For REPLACING functions: Use patch_function — code in ```elixir block after </action>
    4. For SMALL TEXT EDITS (imports, config): Use edit_file
    5. ONE action per response
    6. After lookup_function returns code, use "respond" to analyze it
    7. After BUILD GREEN, if tests exist, use run_tests to verify behavior
    8. After multiple file edits, call commit_changes to atomically verify

    #{build_transaction_section(opts[:transaction_mode], opts[:staged_files])}

    DEFINITION OF DONE:
    1. Build green (mix compile)
    2. Tests green (run_tests returns 0 failures)
    3. Downstream regression green (Giulia auto-verifies dependents)
    4. You verified ALL before using respond
    NEVER claim success from compile alone. If tests or downstream regression failed, fix and re-run.

    GRAPH-AWARE:
    When you see "HUB IMPACT" or "CRITICAL HUB WARNING", be extra careful.
    Hub modules have many dependents — do NOT change their public function signatures.
    Use get_impact_map to check before modifying unfamiliar modules.

    AGENTIC MANDATE:
    You are the AUTONOMOUS DEVELOPER. If you see a syntax error or build failure:
    - DO NOT ask the user to fix it
    - USE patch_function or edit_file to FIX IT YOURSELF
    - Goal: GREEN BUILD + GREEN TESTS

    Do NOT generate fake tool results.
    After a tool succeeds, use RESPOND to give your answer.
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
        build_minimal_prompt(opts)
      else
        build_system_prompt(opts)
      end

    history = opts[:history] || []

    [
      %{role: "system", content: system_prompt}
    ] ++ history ++ [
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
    truncated = if String.length(content) > 2000 do
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
    relevant_asts =
      (mentioned_modules ++ mentioned_files)
      |> Enum.map(&find_relevant_ast/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(3)  # Max 3 files for small models

    if relevant_asts == [] do
      # No specific context, use project summary
      opts[:project_summary] || Store.project_summary()
    else
      format_relevant_context(relevant_asts)
    end
  end

  # ============================================================================
  # Private - Formatting
  # ============================================================================

  defp build_topology_summary do
    try do
      case Giulia.Knowledge.Store.stats() do
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

  defp build_transaction_section(true, staged_files) when is_list(staged_files) and staged_files != [] do
    file_list = Enum.map_join(staged_files, "\n", &"  - #{&1}")
    """
    ## TRANSACTION MODE (Active)
    Your writes are being STAGED, not written to disk.
    - write_file, edit_file, patch_function, write_function → buffer only
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
    - read_file → returns staged content if available
    - commit_changes → atomically flush all changes, compile, test, rollback on failure
    - You MUST call commit_changes before respond
    """
  end

  defp build_transaction_section(_, _), do: ""

  defp format_constitution(nil), do: ""
  defp format_constitution(%{taboos: taboos, patterns: patterns}) when taboos != [] or patterns != [] do
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

  defp find_relevant_ast(module_or_file) do
    cond do
      String.contains?(module_or_file, ".") and String.contains?(module_or_file, "/") ->
        # It's a file path
        case Store.get_ast(module_or_file) do
          {:ok, ast} -> {module_or_file, ast}
          _ -> nil
        end

      String.contains?(module_or_file, ".") ->
        # It's a module name
        case Store.find_module(module_or_file) do
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
