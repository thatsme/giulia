defmodule Giulia.Tools.GetModuleInfo do
  @moduledoc """
  Get module information from the ETS index.

  NO FILE READING REQUIRED - this queries the pre-indexed AST data.
  Instant response, minimal context, perfect for small models.

  This is the "memory" that makes Giulia smarter than stateless tools.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Context.Store

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :module_name, :string
  end

  @impl true
  def name, do: "get_module_info"

  @impl true
  def description, do: "Get information about a module from the index (functions, file path). Faster than reading files."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        module_name: %{
          type: "string",
          description: "Full module name (e.g., 'Giulia.Client', 'Phoenix.Controller')"
        }
      },
      required: ["module_name"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:module_name])
    |> validate_required([:module_name])
  end

  def execute(params, _opts \\ [])

  def execute(%__MODULE__{module_name: module_name}, _opts) do
    case Store.find_module(module_name) do
      {:ok, %{file: file, ast_data: ast_data}} ->
        format_module_info(module_name, file, ast_data)

      :not_found ->
        # Try partial match
        suggest_modules(module_name)
    end
  end

  def execute(%{"module_name" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{module_name: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp format_module_info(module_name, file, ast_data) do
    functions = ast_data[:functions] || []
    imports = ast_data[:imports] || []
    complexity = ast_data[:complexity] || 0
    line_count = ast_data[:line_count] || 0

    public_funcs = functions
    |> Enum.filter(&(&1.type == :def))
    |> Enum.map_join("\n", &"  - #{&1.name}/#{&1.arity} (line #{&1.line})")

    private_funcs = functions
    |> Enum.filter(&(&1.type == :defp))
    |> Enum.map_join("\n", &"  - #{&1.name}/#{&1.arity} (line #{&1.line})")

    deps = imports
    |> Enum.map_join("\n", &"  - #{&1.type} #{&1.module}")

    info = """
    Module: #{module_name}
    File: #{file}
    Lines: #{line_count}
    Complexity: #{complexity}

    Public Functions:
    #{if public_funcs == "", do: "  (none)", else: public_funcs}

    Private Functions:
    #{if private_funcs == "", do: "  (none)", else: private_funcs}

    Dependencies:
    #{if deps == "", do: "  (none)", else: deps}
    """

    {:ok, info}
  end

  defp suggest_modules(partial_name) do
    modules = Store.list_modules()
    partial_lower = String.downcase(partial_name)

    matches = modules
    |> Enum.filter(fn mod ->
      String.contains?(String.downcase(mod.name), partial_lower)
    end)
    |> Enum.map(& &1.name)
    |> Enum.take(5)

    if matches != [] do
      {:ok, "Module '#{partial_name}' not found. Similar modules:\n#{Enum.map_join(matches, "\n", &"  - #{&1}")}"}
    else
      {:error, "Module '#{partial_name}' not found in index. Try running /scan to re-index."}
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

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
