defmodule Giulia.Tools.LookupFunction do
  @moduledoc """
  Look up a function by name using the INDEX, not file search.

  This is the "Senior" approach:
  1. Query ETS index → get file path + line
  2. Slice the function source using AST
  3. Return focused context to LLM

  The LLM never reads whole files. It gets surgical slices.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Context.Store
  alias Giulia.AST.Processor

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :function_name, :string
    field :module, :string
    field :arity, :integer
    field :include_deps, :boolean, default: false
  end

  @impl true
  def name, do: "lookup_function"

  @impl true
  def description do
    "Look up a function from the project index. Returns the function source code. " <>
    "Use this instead of search_code when you know the function name."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        function_name: %{
          type: "string",
          description: "Name of the function (e.g., 'try_repair_json', 'init', 'handle_call')"
        },
        module: %{
          type: "string",
          description: "Module name (e.g., 'Giulia.StructuredOutput'). Optional - if omitted, searches all modules."
        },
        arity: %{
          type: "integer",
          description: "Function arity. Optional - if omitted, returns first match."
        },
        include_deps: %{
          type: "boolean",
          description: "If true, also include private functions called by this function."
        }
      },
      required: ["function_name"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:function_name, :module, :arity, :include_deps])
    |> validate_required([:function_name])
  end

  @impl true
  def execute(params, _opts \\ [])

  def execute(%__MODULE__{} = params, opts) do
    project_path = opts[:project_path]
    do_lookup(params.function_name, params.module, params.arity, params.include_deps || false, project_path)
  end

  def execute(%{"function_name" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{function_name: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # ============================================================================
  # Core Logic
  # ============================================================================

  defp do_lookup(function_name, module_filter, arity, include_deps, project_path) do
    # Step 1: Query the index
    matches = Store.Query.find_function(project_path, function_name, arity)

    # Step 2: Filter by module if specified
    matches = if module_filter do
      Enum.filter(matches, &(&1.module == module_filter))
    else
      matches
    end

    case matches do
      [] ->
        # No matches - suggest similar functions
        suggest_similar(function_name, project_path)

      [match | _rest] ->
        # Found it! Now slice the source
        extract_source(match, include_deps)
    end
  end

  defp extract_source(match, include_deps) do
    file_path = match.file
    func_name = match.name
    arity = match.arity

    case File.read(file_path) do
      {:ok, source} ->
        result = if include_deps do
          Processor.slice_function_with_deps(source, func_name, arity)
        else
          Processor.slice_function(source, func_name, arity)
        end

        case result do
          {:ok, func_source} ->
            header = build_header(match)
            {:ok, header <> func_source}

          {:error, _reason} ->
            # Fallback: return lines around the function
            {:ok, build_header(match) <> Processor.slice_around_line(source, match.line, 15)}
        end

      {:error, reason} ->
        {:error, "Could not read file #{file_path}: #{inspect(reason)}"}
    end
  end

  defp build_header(match) do
    visibility = if match.type in [:defp, :defmacrop, :defguardp], do: "private", else: "public"
    """
    # Module: #{match.module}
    # Function: #{match.name}/#{match.arity} (#{visibility})
    # File: #{Path.basename(match.file)}:#{match.line}

    """
  end

  defp suggest_similar(function_name, project_path) do
    # Get all function names from the index
    all_functions = Store.Query.list_functions(project_path, nil)
    |> Enum.map(&to_string(&1.name))
    |> Enum.uniq()

    # Find similar names using Jaro distance
    similar = all_functions
    |> Enum.filter(&(String.jaro_distance(&1, function_name) > 0.7))
    |> Enum.sort_by(&String.jaro_distance(&1, function_name), :desc)
    |> Enum.take(5)

    if similar != [] do
      {:error, "Function '#{function_name}' not found in index. Did you mean: #{Enum.join(similar, ", ")}?"}
    else
      {:error, "Function '#{function_name}' not found in the project index. Use list_files or search_code to explore."}
    end
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

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
