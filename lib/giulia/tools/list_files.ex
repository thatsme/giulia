defmodule Giulia.Tools.ListFiles do
  @moduledoc """
  List files in a directory within the project sandbox.

  The model's "peripheral vision" - see what files exist before reading them.
  Essential for navigation in unfamiliar codebases.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :path, :string, default: "."
    field :pattern, :string, default: "*"
    field :recursive, :boolean, default: true
  end

  @impl true
  def name, do: "list_files"

  @impl true
  def description, do: "List files in a directory. Use pattern for filtering (e.g., '*.ex')"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Directory path relative to project root (default: '.')"
        },
        pattern: %{
          type: "string",
          description: "Glob pattern to filter files (default: '*', use '*.ex' for Elixir files)"
        },
        recursive: %{
          type: "boolean",
          description: "If true, search recursively (default: true)"
        }
      },
      required: []
    }
  end

  def changeset(params) do
    cast(%__MODULE__{}, params, [:path, :pattern, :recursive])
  end

  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{path: path, pattern: pattern, recursive: recursive}, opts) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, path) do
      {:ok, safe_path} ->
        do_list(safe_path, pattern, recursive)

      {:error, :sandbox_violation} ->
        {:error, PathSandbox.violation_message(path, sandbox)}
    end
  end

  def execute(%{"path" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # Directories to exclude from search (dependencies, build artifacts)
  @excluded_dirs ["deps", "_build", ".git", ".elixir_ls", "node_modules", ".giulia"]

  defp do_list(safe_path, pattern, recursive) do
    glob_pattern = if recursive do
      Path.join([safe_path, "**", pattern])
    else
      Path.join(safe_path, pattern)
    end

    files = Path.wildcard(glob_pattern)
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&in_excluded_dir?/1)
    |> Enum.map(&Path.relative_to(&1, safe_path))
    |> Enum.sort()
    |> Enum.take(100)  # Limit for small models

    if files == [] do
      {:ok, "No files found matching pattern '#{pattern}' in #{safe_path}"}
    else
      {:ok, Enum.join(files, "\n")}
    end
  end

  defp in_excluded_dir?(path) do
    parts = Path.split(path)
    Enum.any?(@excluded_dirs, fn dir -> dir in parts end)
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
