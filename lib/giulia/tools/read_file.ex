defmodule Giulia.Tools.ReadFile do
  @moduledoc """
  Structured tool for reading files.

  Uses Ecto schema for structured LLM tool calls.
  All file operations use native Elixir File module - no shell piping.

  SECURITY: All paths are validated against the ProjectContext's sandbox.
  Giulia can ONLY read files within the project where GIULIA.md lives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :path, :string
  end

  # Registry callbacks

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read the contents of a file at the given path (must be within project root)"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Path to the file (relative to project root or absolute within project)"}
      },
      required: ["path"]
    }
  end

  # Changeset (basic validation - real security is in execute)

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:path])
    |> validate_required([:path])
  end

  @doc """
  Execute the read_file tool with a validated struct.

  If a sandbox is provided (from ProjectContext), validates path security.
  Otherwise, uses a default sandbox from the current working directory.
  """
  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(input, opts \\ [])

  def execute(%__MODULE__{path: path}, opts) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, path) do
      {:ok, safe_path} ->
        do_read(safe_path)

      {:error, :sandbox_violation} ->
        {:error, PathSandbox.violation_message(path, sandbox)}
    end
  end

  def execute(%{"path" => _} = params, opts) do
    case Giulia.StructuredOutput.parse_map(params, __MODULE__) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{path: _} = params, opts) do
    case Giulia.StructuredOutput.parse_map(stringify_keys(params), __MODULE__) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # Handle empty or invalid params gracefully
  def execute(%{} = params, _opts) when map_size(params) == 0 do
    {:error, :missing_path_parameter}
  end

  def execute(params, _opts) do
    {:error, {:invalid_params, "Expected map with 'path' key, got: #{inspect(params)}"}}
  end

  # Private

  defp do_read(safe_path) do
    case File.read(safe_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, "File not found: #{safe_path}"}

      {:error, :eisdir} ->
        {:error, "Path is a directory: #{safe_path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{safe_path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp get_sandbox(opts) do
    case Keyword.get(opts, :sandbox) do
      nil ->
        # Default to current working directory as sandbox root
        # This is a fallback - proper usage should always provide a sandbox
        project_root = get_project_root()
        PathSandbox.new(project_root)

      sandbox ->
        sandbox
    end
  end

  defp get_project_root do
    # Try to find GIULIA.md walking up from cwd
    cwd = File.cwd!()
    find_project_root(cwd) || cwd
  end

  defp find_project_root(path) do
    giulia_md = Path.join(path, "GIULIA.md")

    if File.exists?(giulia_md) do
      path
    else
      parent = Path.dirname(path)

      if parent == path do
        nil
      else
        find_project_root(parent)
      end
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
