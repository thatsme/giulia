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

  alias Giulia.Core.{PathSandbox, ProjectContext}

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field(:path, :string)
    field(:content, :string)
    field(:explanation, :string)
  end

  # Registry callbacks

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do:
      "Write content to a file (must be within project root). Creates parent directories if needed."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file (relative to project root or absolute within project)"
        },
        content: %{type: "string", description: "Content to write to the file"},
        explanation: %{
          type: "string",
          description: "Why this change is being made (for audit trail)"
        }
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
  def execute(input, opts \\ []) do
    case Giulia.StructuredOutput.parse_map(input, __MODULE__) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # Private

  # Maximum allowed content reduction (30%) - prevents accidental mass deletion
  @max_reduction_threshold 0.30

  defp do_write(safe_path, content, explanation, opts \\ []) do
    # NUCLEAR SAFEGUARD: Check for destructive writes
    # Can be bypassed for escalation repairs (we trust Groq/Gemini)
    bypass = Keyword.get(opts, :bypass_safeguard, false)

    if bypass do
      do_write_internal(safe_path, content, explanation)
    else
      case check_destructive_write(safe_path, content) do
        :ok ->
          do_write_internal(safe_path, content, explanation)

        {:error, _} = error ->
          error
      end
    end
  end

  # Check if this write would delete too much content (>30% reduction)
  defp check_destructive_write(path, new_content) do
    case File.read(path) do
      {:ok, existing_content} ->
        old_size = byte_size(existing_content)
        new_size = byte_size(new_content)

        # Only check reduction on files > 100 bytes (ignore tiny files)
        if old_size > 100 do
          reduction = (old_size - new_size) / old_size

          if reduction > @max_reduction_threshold do
            old_lines = existing_content |> String.split("\n") |> length()
            new_lines = new_content |> String.split("\n") |> length()

            {:error,
             """
             DESTRUCTIVE WRITE BLOCKED: You attempted to reduce file size by #{Float.round(reduction * 100, 1)}%.

             File: #{Path.basename(path)}
             Original: #{old_lines} lines (#{old_size} bytes)
             Proposed: #{new_lines} lines (#{new_size} bytes)

             This looks like you may be writing to the WRONG FILE or have incomplete content.

             If this was intentional (deleting code), use edit_file with the specific section to remove.
             Otherwise, check your file path and try again.
             """}
          else
            :ok
          end
        else
          :ok
        end

      {:error, :enoent} ->
        # New file - no existing content to compare
        :ok

      {:error, _} ->
        # Can't read file - proceed with caution
        :ok
    end
  end

  defp do_write_internal(safe_path, content, explanation) do
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
