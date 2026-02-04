defmodule Giulia.Tools.WriteFile do
  @moduledoc """
  Structured tool for writing files.

  Uses Ecto schema for structured LLM tool calls.
  All file operations use native Elixir File module - no shell piping.

  SECURITY: All paths are validated against the ProjectContext's sandbox.
  Giulia can ONLY write files within the project where GIULIA.md lives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :path, :string
    field :content, :string
    field :explanation, :string
  end

  # Registry callbacks

  @impl true
  def name, do: "write_file"

  @impl true
  def description, do: "Write content to a file (must be within project root). Creates parent directories if needed."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Path to the file (relative to project root or absolute within project)"},
        content: %{type: "string", description: "Content to write to the file"},
        explanation: %{type: "string", description: "Why this change is being made (for audit trail)"}
      },
      required: ["path", "content"]
    }
  end

  # Changeset (basic validation - real security is in execute)

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:path, :content, :explanation])
    |> validate_required([:path, :content])
  end

  @doc """
  Execute the write_file tool with a validated struct.

  If a sandbox is provided (from ProjectContext), validates path security.
  Otherwise, uses a default sandbox from the current working directory.
  """
  def execute(input, opts \\ [])

  def execute(%__MODULE__{path: path, content: content, explanation: explanation}, opts) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, path) do
      {:ok, safe_path} ->
        do_write(safe_path, content, explanation)

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

  # Private

  defp do_write(safe_path, content, explanation) do
    # Ensure parent directory exists
    safe_path
    |> Path.dirname()
    |> File.mkdir_p()

    case File.write(safe_path, content) do
      :ok ->
        # Trigger re-indexing if it's an Elixir file
        if String.ends_with?(safe_path, [".ex", ".exs"]) do
          Giulia.Context.Indexer.scan_file(safe_path)
        end

        msg = build_success_message(safe_path, content, explanation)
        {:ok, msg}

      {:error, :eacces} ->
        {:error, "Permission denied: #{safe_path}"}

      {:error, :enospc} ->
        {:error, "No space left on device"}

      {:error, reason} ->
        {:error, "Failed to write file: #{inspect(reason)}"}
    end
  end

  defp build_success_message(path, content, explanation) do
    lines = content |> String.split("\n") |> length()
    bytes = byte_size(content)

    base = "File written: #{path} (#{lines} lines, #{bytes} bytes)"

    if explanation do
      base <> "\nReason: #{explanation}"
    else
      base
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
