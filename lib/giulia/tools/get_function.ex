defmodule Giulia.Tools.GetFunction do
  @moduledoc """
  Extract a specific function from source code using AST.

  THIS IS WHERE GIULIA KILLS HER FATHER.

  Claude Code sends whole files. Giulia sends slices.
  A 3B model with 20 lines of focused context beats
  a 70B model drowning in 500 lines of irrelevant code.

  Uses Sourceror for AST-based extraction:
  - Preserves formatting
  - Can include dependencies
  - Returns exactly what the model needs
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox
  alias Giulia.AST.Processor

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field(:file, :string)
    field(:function_name, :string)
    field(:arity, :integer)
    field(:include_deps, :boolean, default: false)
  end

  @impl true
  def name, do: "get_function"

  @impl true
  def description,
    do:
      "Extract a specific function from a file by name. More efficient than reading the whole file."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        file: %{
          type: "string",
          description: "Path to the file containing the function"
        },
        function_name: %{
          type: "string",
          description: "Name of the function to extract (e.g., 'init', 'handle_call')"
        },
        arity: %{
          type: "integer",
          description: "Function arity (number of arguments). If omitted, returns first match."
        },
        include_deps: %{
          type: "boolean",
          description: "If true, also include private functions called by this function"
        }
      },
      required: ["file", "function_name"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:file, :function_name, :arity, :include_deps])
    |> validate_required([:file, :function_name])
  end

  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(params, opts \\ [])

  def execute(
        %__MODULE__{
          file: file,
          function_name: func_name,
          arity: arity,
          include_deps: include_deps
        },
        opts
      ) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, file) do
      {:ok, safe_path} ->
        do_extract(safe_path, func_name, arity, include_deps)

      {:error, :sandbox_violation} ->
        {:error, PathSandbox.violation_message(file, sandbox)}
    end
  end

  def execute(%{"file" => _, "function_name" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # Handle when model sends "module" instead of "file" - look up the file from index
  def execute(%{"module" => module, "function_name" => _func_name} = params, opts) do
    project_path = opts[:project_path]

    case Giulia.Context.Store.Query.find_module(project_path, module) do
      {:ok, %{file: file_path}} ->
        new_params = Map.delete(Map.put(params, "file", file_path), "module")
        execute(new_params, opts)

      :not_found ->
        {:error,
         "Module '#{module}' not found in project index. Use /scan first or provide 'file' parameter."}
    end
  end

  def execute(%{file: _, function_name: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp do_extract(file_path, func_name, arity, include_deps) do
    # Convert function name to atom
    func_atom = String.to_existing_atom(func_name)

    case File.read(file_path) do
      {:ok, source} ->
        extract_function(source, func_atom, arity, include_deps, file_path)

      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp extract_function(source, func_name, arity, include_deps, file_path) do
    # Determine arity if not provided
    actual_arity = arity || find_function_arity(source, func_name)

    result =
      if include_deps do
        Processor.slice_function_with_deps(source, func_name, actual_arity || 0)
      else
        Processor.slice_function(source, func_name, actual_arity || 0)
      end

    case result do
      {:ok, func_source} ->
        # Add file context
        header =
          "# From: #{Path.basename(file_path)}\n# Function: #{func_name}/#{actual_arity || "?"}\n\n"

        {:ok, header <> func_source}

      {:error, :function_not_found} ->
        # Try to find similar function names
        similar = find_similar_functions(source, func_name)

        if similar != [] do
          {:error,
           "Function '#{func_name}' not found. Did you mean: #{Enum.join(similar, ", ")}?"}
        else
          {:error, "Function '#{func_name}' not found in #{file_path}"}
        end

      {:error, reason} ->
        {:error, "Failed to extract function: #{inspect(reason)}"}
    end
  end

  defp find_function_arity(source, func_name) do
    # func_name might be atom or string, normalize to string for comparison
    func_str = to_string(func_name)

    case Processor.parse(source) do
      {:ok, ast, _} ->
        functions = Processor.extract_functions(ast)

        case Enum.find(functions, &(to_string(&1.name) == func_str)) do
          %{arity: arity} -> arity
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp find_similar_functions(source, target_name) do
    target_str = to_string(target_name)

    case Processor.parse(source) do
      {:ok, ast, _} ->
        Processor.extract_functions(ast)
        |> Enum.map(&to_string(&1.name))
        |> Enum.filter(&(String.jaro_distance(&1, target_str) > 0.7))
        |> Enum.take(3)

      {:error, _} ->
        []
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
