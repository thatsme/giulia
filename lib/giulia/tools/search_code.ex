defmodule Giulia.Tools.SearchCode do
  @moduledoc """
  Search for patterns in code files.

  The model's "ctrl+shift+f" - find occurrences across the codebase.
  Returns file paths and line numbers, not full content (keeps context small).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :pattern, :string
    field :file_pattern, :string, default: "*.ex"
    field :case_sensitive, :boolean, default: false
    field :max_results, :integer, default: 20
  end

  @impl true
  def name, do: "search_code"

  @impl true
  def description, do: "Search for a pattern in code files. Returns matching lines with file paths."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "Text or regex pattern to search for"
        },
        file_pattern: %{
          type: "string",
          description: "Glob pattern for files to search (default: '*.ex')"
        },
        case_sensitive: %{
          type: "boolean",
          description: "Case-sensitive search (default: false)"
        },
        max_results: %{
          type: "integer",
          description: "Maximum number of results (default: 20)"
        }
      },
      required: ["pattern"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:pattern, :file_pattern, :case_sensitive, :max_results])
    |> validate_required([:pattern])
  end

  def execute(params, opts \\ [])

  def execute(%__MODULE__{pattern: pattern, file_pattern: file_pattern, case_sensitive: case_sensitive, max_results: max_results}, opts) do
    sandbox = get_sandbox(opts)

    # Get all matching files in sandbox
    glob = Path.join([sandbox.root, "**", file_pattern])
    files = Path.wildcard(glob)
    |> Enum.reject(&File.dir?/1)
    |> Enum.filter(&PathSandbox.safe?(&1, sandbox))

    # Search each file
    results = files
    |> Enum.flat_map(&search_file(&1, pattern, case_sensitive, sandbox.root))
    |> Enum.take(max_results)

    if results == [] do
      {:ok, "No matches found for '#{pattern}'"}
    else
      formatted = Enum.map_join(results, "\n", fn {file, line_num, line} ->
        "#{file}:#{line_num}: #{String.trim(line)}"
      end)
      {:ok, formatted}
    end
  end

  def execute(%{"pattern" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{pattern: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp search_file(file_path, pattern, case_sensitive, root) do
    case File.read(file_path) do
      {:ok, content} ->
        relative_path = Path.relative_to(file_path, root)

        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          matches?(line, pattern, case_sensitive)
        end)
        |> Enum.map(fn {line, num} -> {relative_path, num, line} end)

      {:error, _} ->
        []
    end
  end

  defp matches?(line, pattern, case_sensitive) do
    if case_sensitive do
      String.contains?(line, pattern)
    else
      String.contains?(String.downcase(line), String.downcase(pattern))
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
