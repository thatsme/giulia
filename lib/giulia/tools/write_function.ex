defmodule Giulia.Tools.WriteFunction do
  @moduledoc """
  AST-based function replacement - easier for LLMs than string matching.

  Instead of:
    edit_file(file: "...", old_text: "<exact match>", new_text: "<new code>")

  The LLM can:
    write_function(module: "Giulia.Foo", function: "bar", arity: 2, code: "<new code>")

  Giulia uses Sourceror to find and replace the specific function AST node.
  This is more robust because:
  1. No need to match whitespace/formatting exactly
  2. No JSON escaping headaches for the LLM
  3. Works even if the file was reformatted
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Context.Store
  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :module, :string
    field :function_name, :string
    field :arity, :integer
    field :code, :string
  end

  @impl true
  def name, do: "write_function"

  @impl true
  def description do
    "Replace a function in a module with new code. Uses AST-based replacement - " <>
    "easier than edit_file because you don't need exact string matching."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        module: %{
          type: "string",
          description: "Full module name (e.g., 'Giulia.StructuredOutput')"
        },
        function_name: %{
          type: "string",
          description: "Name of the function to replace"
        },
        arity: %{
          type: "integer",
          description: "Function arity (number of arguments)"
        },
        code: %{
          type: "string",
          description: "Complete new function code including def/defp"
        }
      },
      required: ["module", "function_name", "arity", "code"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:module, :function_name, :arity, :code])
    |> validate_required([:module, :function_name, :arity, :code])
  end

  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{} = params, opts) do
    do_write_function(params.module, params.function_name, params.arity, params.code, opts)
  end

  def execute(%{"module" => _, "function_name" => _, "arity" => _, "code" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{module: _, function_name: _, arity: _, code: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # ============================================================================
  # Core Logic
  # ============================================================================

  defp do_write_function(module_name, func_name, arity, new_code, opts) do
    require Logger

    try do
      # Step 1: Find the module in the index
      project_path = opts[:project_path]
      case Store.find_module(project_path, module_name) do
        {:ok, %{file: file_path}} ->
          sandbox = get_sandbox(opts)

          case PathSandbox.validate(sandbox, file_path) do
            {:ok, safe_path} ->
              replace_function_in_file(safe_path, func_name, arity, new_code)

            {:error, :sandbox_violation} ->
              {:error, PathSandbox.violation_message(file_path, sandbox)}
          end

        :not_found ->
          {:error, "Module '#{module_name}' not found in project index. Run /scan first."}
      end
    rescue
      e ->
        Logger.error("WriteFunction CRASH: #{Exception.format(:error, e, __STACKTRACE__)}")
        {:error, "Internal error: #{inspect(e)}"}
    end
  end

  defp replace_function_in_file(file_path, func_name, arity, new_code) do
    require Logger
    func_atom = String.to_atom(func_name)
    Logger.info("WriteFunction: Starting replacement of #{func_name}/#{arity} in #{file_path}")

    with {:ok, source} <- File.read(file_path),
         _ <- Logger.debug("WriteFunction: Read file (#{byte_size(source)} bytes)"),
         {:ok, file_ast} <- parse_source(source),
         _ <- Logger.debug("WriteFunction: Parsed file AST"),
         {:ok, new_func_ast} <- parse_new_function(new_code),
         _ <- Logger.debug("WriteFunction: Parsed new function AST") do

      # Find and replace the function
      Logger.debug("WriteFunction: Starting AST replacement")
      {new_ast, replaced?} = replace_function_ast(file_ast, func_atom, arity, new_func_ast)
      Logger.debug("WriteFunction: AST replacement done, replaced=#{replaced?}")

      if replaced? do
        # Convert back to string with proper formatting
        Logger.debug("WriteFunction: Converting AST to string")
        new_source = Macro.to_string(new_ast)
        Logger.debug("WriteFunction: Generated source (#{byte_size(new_source)} bytes)")

        # Run through formatter for clean output
        formatted = format_source(new_source)

        Logger.info("WriteFunction: Writing to #{file_path}")
        case File.write(file_path, formatted) do
          :ok ->
            Logger.info("WriteFunction: Success!")
            {:ok, "Successfully replaced #{func_name}/#{arity} in #{Path.basename(file_path)}"}

          {:error, reason} ->
            Logger.error("WriteFunction: Write failed: #{inspect(reason)}")
            {:error, "Failed to write file: #{inspect(reason)}"}
        end
      else
        Logger.warning("WriteFunction: Function not found in file")
        {:error, "Function #{func_name}/#{arity} not found in #{Path.basename(file_path)}"}
      end
    else
      {:error, :enoent} ->
        Logger.error("WriteFunction: File not found: #{file_path}")
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        Logger.error("WriteFunction: Failed: #{inspect(reason)}")
        {:error, "Failed: #{inspect(reason)}"}
    end
  end

  # Use Elixir's standard parser - produces AST compatible with Macro.to_string
  # Returns descriptive errors for the model to understand
  defp parse_source(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} ->
        line = meta[:line] || 1
        # Extract context around the error
        lines = String.split(source, "\n")
        context = extract_error_context_lines(lines, line)
        {:error, "Syntax error at line #{line}: #{message} #{inspect(token)}\n\nContext:\n#{context}"}
    end
  end

  defp parse_new_function(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} ->
        line = meta[:line] || 1
        col = meta[:column] || 1
        lines = String.split(code, "\n")
        context = extract_error_context_lines(lines, line)
        {:error, """
        SYNTAX ERROR in your proposed code at line #{line}, column #{col}:
        #{message} #{inspect(token)}

        YOUR CODE (showing error location):
        #{context}

        FULL CODE YOU SENT:
        #{code}

        Please fix the syntax error and try again with edit_file.
        """}
    end
  end

  # Show 3 lines before and after the error line
  defp extract_error_context_lines(lines, error_line) do
    start_line = max(1, error_line - 3)
    end_line = min(length(lines), error_line + 3)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_, idx} -> idx >= start_line and idx <= end_line end)
    |> Enum.map(fn {line, idx} ->
      marker = if idx == error_line, do: ">>> ", else: "    "
      "#{marker}#{idx}: #{line}"
    end)
    |> Enum.join("\n")
  end

  # Simple formatter - just ensure clean output
  defp format_source(source) do
    # Add trailing newline if missing
    if String.ends_with?(source, "\n"), do: source, else: source <> "\n"
  end

  defp replace_function_ast(ast, func_name, arity, new_func_ast) do
    require Logger
    Logger.debug("replace_function_ast: Looking for #{func_name}/#{arity}")

    {new_ast, found} = Macro.prewalk(ast, false, fn
      # Match function definition WITH guard clause
      # AST: {:def, meta, [{:when, _, [{name, _, args}, guard]}, body]}
      {def_type, _meta, [{:when, _, [{name, _, args} | _guard]} | _rest]} = node, found
      when def_type in [:def, :defp] and is_atom(name) ->
        Logger.debug("Found guarded function: #{name}/#{length(args || [])}")
        if name == func_name and length(args || []) == arity do
          Logger.info("MATCH! Replacing #{name}/#{arity}")
          {new_func_ast, true}
        else
          {node, found}
        end

      # Match function definition WITHOUT guard clause
      # AST: {:def, meta, [{name, _, args}, body]}
      {def_type, _meta, [{name, _, args} | _rest]} = node, found
      when def_type in [:def, :defp] and is_atom(name) ->
        Logger.debug("Found function: #{name}/#{length(args || [])}")
        if name == func_name and length(args || []) == arity do
          Logger.info("MATCH! Replacing #{name}/#{arity}")
          {new_func_ast, true}
        else
          {node, found}
        end

      node, found ->
        {node, found}
    end)

    Logger.debug("replace_function_ast: found=#{found}")
    {new_ast, found}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_params(params) do
    changeset = changeset(params)
    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp get_sandbox(opts) do
    case Keyword.get(opts, :sandbox) do
      nil -> PathSandbox.new(File.cwd!())
      sandbox -> sandbox
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
