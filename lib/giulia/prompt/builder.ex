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

    #{format_constitution(constitution)}

    ## Response Schema
    Your response MUST be valid JSON matching ONE of these formats:

    1. Tool Call:
    {"tool": "tool_name", "parameters": {"param1": "value1"}}

    2. Final Response (when task is complete):
    {"tool": "respond", "parameters": {"message": "Your response here"}}

    3. Thinking (if you need to reason):
    {"tool": "think", "parameters": {"thought": "reasoning here"}}

    ## Examples

    User: "What's in lib/giulia/client.ex?"
    Response: {"tool": "read_file", "parameters": {"path": "lib/giulia/client.ex"}}

    User: "Explain the init function"
    Response: {"tool": "read_file", "parameters": {"path": "lib/giulia/application.ex"}}

    After reading:
    Response: {"tool": "respond", "parameters": {"message": "The init function initializes..."}}

    ## Constraints
    1. ONLY respond with JSON - never plain text
    2. ONLY use tools from the Available Tools list
    3. NEVER access files outside the project root
    4. If unsure, use read_file or search_code to gather information first
    5. If search returns "No matches found", the file/function does NOT exist in this project
    6. If you cannot find something after 2 searches, use respond to explain what you tried
    7. Dependencies (deps/) are NOT searchable - only project source files
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
    <action>
    {"tool": "TOOL_NAME", "parameters": {"PARAM": "VALUE"}}
    </action>

    EXAMPLES:

    To read a file:
    <action>
    {"tool": "read_file", "parameters": {"path": "lib/giulia/client.ex"}}
    </action>

    To search code:
    <action>
    {"tool": "search_code", "parameters": {"query": "defmodule Giulia.Client"}}
    </action>

    To respond to the user:
    <action>
    {"tool": "respond", "parameters": {"message": "The file contains..."}}
    </action>

    RULES:
    1. ALWAYS include "parameters" with required values
    2. read_file REQUIRES "path" parameter
    3. ONE action per response
    4. NEVER make up paths - use list_files first
    5. After reading a file, IMMEDIATELY use "respond" to answer the user
    6. Do NOT use "think" more than once - go straight to "respond"

    CRITICAL: Stop IMMEDIATELY after </action>.
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

  def format_observation(tool_name, {:error, :enoent}) do
    """
    ERROR: File not found. The path does NOT exist.
    Use list_files to see actual paths in the directory.
    Use search_code to find files by content.
    Do NOT guess paths - verify they exist first.
    """
  end

  def format_observation(tool_name, {:error, :sandbox_violation}) do
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
