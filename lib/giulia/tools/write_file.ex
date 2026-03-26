defmodule Giulia.Tools.WriteFile do
  @moduledoc """
  Structured tool for writing files.

  Uses Ecto schema for structured LLM tool calls.
  All file operations use native Elixir File module - no shell piping.

  SECURITY: All paths are validated against the ProjectContext's sandbox.
  Giulia can ONLY write files within the project where GIULIA.md lives.

  NOTE: The Orchestrator intercepts write_file calls via the staging buffer
  (Transactional Exoskeleton). The execute/2 here is a fallback for direct use.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

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
  Execute the write_file tool.

  Normally intercepted by the Orchestrator's staging buffer.
  This implementation handles direct calls (e.g., from tests or iex).
  """
  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{path: path, content: content, explanation: explanation}, opts) do
    project_path = Keyword.get(opts, :project_path) || File.cwd!()
    sandbox = PathSandbox.new(project_path)

    case PathSandbox.validate(sandbox, path) do
      {:ok, safe_path} ->
        safe_path |> Path.dirname() |> File.mkdir_p()

        case File.write(safe_path, content) do
          :ok ->
            if String.ends_with?(safe_path, [".ex", ".exs"]) do
              Giulia.Context.Indexer.scan_file(safe_path)
            end

            lines = content |> String.split("\n") |> length()
            bytes = byte_size(content)
            msg = "File written: #{safe_path} (#{lines} lines, #{bytes} bytes)"
            msg = if explanation, do: msg <> "\nReason: #{explanation}", else: msg
            {:ok, msg}

          {:error, reason} ->
            {:error, "Failed to write file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Path rejected by sandbox: #{inspect(reason)}"}
    end
  end

  def execute(params, opts) do
    case Giulia.StructuredOutput.parse_map(params, __MODULE__) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end
end
