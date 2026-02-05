defmodule Giulia.Tools.GetContext do
  @moduledoc """
  Get code context around a specific line number.

  Perfect for debugging - when you have an error at line 42,
  get the surrounding context without loading the whole file.

  Uses AST when possible to find the containing function,
  otherwise falls back to line-based extraction.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox
  alias Giulia.AST.Processor

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :file, :string
    field :line, :integer
    field :context_lines, :integer, default: 10
    field :smart, :boolean, default: true
  end

  @impl true
  def name, do: "get_context"

  @impl true
  def description, do: "Get code context around a specific line number. Use for debugging errors."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        file: %{
          type: "string",
          description: "Path to the file"
        },
        line: %{
          type: "integer",
          description: "Line number to get context for"
        },
        context_lines: %{
          type: "integer",
          description: "Number of lines before/after to include (default: 10)"
        },
        smart: %{
          type: "boolean",
          description: "If true, try to extract the whole containing function (default: true)"
        }
      },
      required: ["file", "line"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:file, :line, :context_lines, :smart])
    |> validate_required([:file, :line])
    |> validate_number(:line, greater_than: 0)
    |> validate_number(:context_lines, greater_than: 0, less_than: 50)
  end

  def execute(params, opts \\ [])

  def execute(%__MODULE__{file: file, line: line, context_lines: ctx_lines, smart: smart}, opts) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, file) do
      {:ok, safe_path} ->
        do_get_context(safe_path, line, ctx_lines, smart)

      {:error, :sandbox_violation} ->
        {:error, PathSandbox.violation_message(file, sandbox)}
    end
  end

  def execute(%{"file" => _, "line" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{file: _, line: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp do_get_context(file_path, line, ctx_lines, smart) do
    case File.read(file_path) do
      {:ok, source} ->
        if smart do
          smart_context(source, line, ctx_lines, file_path)
        else
          simple_context(source, line, ctx_lines, file_path)
        end

      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp smart_context(source, line, fallback_ctx, file_path) do
    # Try to find the function containing this line
    case Processor.parse(source) do
      {:ok, ast, _} ->
        case find_containing_function(ast, line) do
          {:ok, func_name, func_source} ->
            header = "# #{Path.basename(file_path)} - Function containing line #{line}\n"
            header <> "# Function: #{func_name}\n\n"
            {:ok, header <> func_source}

          :not_found ->
            # Fall back to line-based
            simple_context(source, line, fallback_ctx, file_path)
        end

      {:error, _} ->
        simple_context(source, line, fallback_ctx, file_path)
    end
  end

  defp simple_context(source, line, ctx_lines, file_path) do
    context = Processor.slice_around_line(source, line, ctx_lines)
    header = "# #{Path.basename(file_path)} - Lines around #{line}\n\n"
    {:ok, header <> context}
  end

  defp find_containing_function(ast, target_line) do
    result = ast
    |> Sourceror.prewalk(nil, fn
      {def_type, meta, [{name, _, args} | _]} = node, nil
      when def_type in [:def, :defp] ->
        start_line = Keyword.get(meta, :line, 0)
        end_line = get_end_line(meta, start_line)

        if target_line >= start_line and target_line <= end_line do
          arity = length(args || [])
          func_source = Macro.to_string(node)
          {node, {:found, "#{name}/#{arity}", func_source}}
        else
          {node, nil}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)

    case result do
      {:found, name, source} -> {:ok, name, source}
      nil -> :not_found
    end
  end

  defp get_end_line(meta, default) do
    case Keyword.get(meta, :end_of_expression) do
      nil -> default + 20  # Estimate
      end_meta -> Keyword.get(end_meta, :line, default)
    end
  end

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
