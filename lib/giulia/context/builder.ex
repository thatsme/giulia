defmodule Giulia.Context.Builder do
  @moduledoc """
  Dynamic System Prompt Builder.

  Builds the "System Constitution" that constrains the model.
  Injects capabilities, environment awareness, and strict JSON constraints.

  Every message to the model includes:
  - Available tools (auto-discovered from registry)
  - Project state (from ETS store)
  - Environment info (OS, paths, etc.)
  - Strict JSON output constraints
  """

  alias Giulia.Tools.Registry
  alias Giulia.Context.Store

  @doc """
  Build the full system prompt with all context.
  """
  def build_system_prompt(opts \\ []) do
    project_path = opts[:project_path] || get_project_path()

    """
    #{constitution()}

    #{capabilities_section()}

    #{environment_section(project_path)}

    #{project_state_section(project_path)}

    #{constraints_section()}
    """
  end

  @doc """
  Build a minimal system prompt (for small models with limited context).
  """
  def build_minimal_prompt(_opts \\ []) do
    """
    #{constitution()}

    #{capabilities_section()}

    #{constraints_section()}
    """
  end

  @doc """
  Build a correction message when a tool call fails validation.
  """
  def build_correction_message(tool_name, errors, valid_options \\ nil) do
    error_text = format_validation_errors(errors)

    base = """
    VALIDATION ERROR for tool "#{tool_name}":
    #{error_text}
    """

    if valid_options do
      base <> "\nValid options: #{inspect(valid_options)}"
    else
      base
    end
  end

  @doc """
  Build a "stuck" intervention message when the model is looping.
  """
  def build_intervention_message(attempt_count, last_errors, opts \\ []) do
    project_path = opts[:project_path] || get_project_path()

    """
    INTERVENTION: You have failed #{attempt_count} consecutive attempts.

    Last errors:
    #{Enum.map_join(last_errors, "\n", &"- #{&1}")}

    You are stuck. Here is the reality of the code again:

    #{project_state_section(project_path)}

    START OVER with a different approach. Do not repeat the same action.
    """
  end

  @doc """
  Build an observation message after tool execution.
  """
  def build_observation(tool_name, result) do
    case result do
      {:ok, output} ->
        "OBSERVATION [#{tool_name}]: Success\n#{truncate(output, 2000)}"

      {:error, reason} ->
        "OBSERVATION [#{tool_name}]: Failed - #{inspect(reason)}"
    end
  end

  # Private - Sections

  defp constitution do
    """
    === CONSTITUTION ===
    You are Giulia, an AI development agent built in Elixir.
    You are running as a BEAM process with persistent state.
    You execute actions through structured tool calls.
    You do NOT have direct shell access - all operations go through tools.
    """
  end

  defp capabilities_section do
    tools = Registry.list_tools()

    tool_descriptions =
      tools
      |> Enum.map_join("\n", fn t ->
        params = t.parameters[:properties] || %{}
        param_list = params |> Map.keys() |> Enum.join(", ")
        "- #{t.name}(#{param_list}): #{t.description}"
      end)

    """
    === AVAILABLE TOOLS ===
    #{tool_descriptions}

    To use a tool, respond with a JSON object matching the tool's parameters.
    """
  end

  defp environment_section(project_path) do
    os = case :os.type() do
      {:win32, _} -> "Windows"
      {:unix, :darwin} -> "macOS"
      {:unix, _} -> "Linux"
    end

    """
    === ENVIRONMENT ===
    Operating System: #{os}
    Project Root: #{project_path || "not set"}
    Elixir Version: #{System.version()}
    AST Engine: Sourceror (native Elixir)
    """
  end

  defp project_state_section(project_path) do
    case Store.stats(project_path) do
      %{ast_files: 0} ->
        "=== PROJECT STATE ===\nNo files indexed yet."

      %{ast_files: count} ->
        files_summary = build_files_summary(project_path)

        """
        === PROJECT STATE ===
        Indexed Files: #{count}

        #{files_summary}
        """
    end
  end

  defp build_files_summary(project_path) do
    Store.all_asts(project_path)
    |> Enum.take(10)  # Limit to first 10 files
    |> Enum.map_join("\n", fn {path, info} ->
      modules = Enum.map_join(info.modules, ", ", & &1.name)
      funcs = length(info.functions)
      "- #{Path.basename(path)}: #{modules} (#{funcs} functions)"
    end)
  end

  defp constraints_section do
    """
    === CONSTRAINTS ===
    1. You MUST respond with valid JSON matching one of the available tools.
    2. NO conversational filler. If you need to think, use the "explanation" field.
    3. If a path doesn't exist, I will tell you. Do not guess paths.
    4. If you fail validation, I will send you the errors. Fix them.
    5. Do NOT repeat a failed action more than twice.
    """
  end

  defp get_project_path do
    case Store.get(:project_path) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  defp format_validation_errors(errors) when is_map(errors) do
    errors
    |> Enum.map_join("\n", fn {field, messages} ->
      "  #{field}: #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end

  defp format_validation_errors(errors), do: inspect(errors)

  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "\n... [truncated]"
    else
      str
    end
  end

  defp truncate(other, _), do: inspect(other)
end
