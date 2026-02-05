defmodule Giulia.Tools.EditFile do
  @moduledoc """
  Surgical file editing - replace specific text without rewriting the whole file.

  Better than write_file because:
  1. Smaller prompts (just the change, not the whole file)
  2. Less error-prone (can't accidentally delete code)
  3. Works with the AST slicer (edit just the function you extracted)

  Uses search-and-replace semantics:
  - old_text must exist exactly once in the file
  - Replaced with new_text
  - If old_text not found, error with suggestions
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :file, :string
    field :old_text, :string
    field :new_text, :string
  end

  @impl true
  def name, do: "edit_file"

  @impl true
  def description, do: "Replace specific text in a file. old_text must match exactly."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        file: %{
          type: "string",
          description: "Path to the file to edit"
        },
        old_text: %{
          type: "string",
          description: "Exact text to find and replace (must exist in file)"
        },
        new_text: %{
          type: "string",
          description: "Text to replace old_text with"
        }
      },
      required: ["file", "old_text", "new_text"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:file, :old_text, :new_text])
    |> validate_required([:file, :old_text, :new_text])
  end

  def execute(params, opts \\ [])

  def execute(%__MODULE__{file: file, old_text: old_text, new_text: new_text}, opts) do
    sandbox = get_sandbox(opts)

    case PathSandbox.validate(sandbox, file) do
      {:ok, safe_path} ->
        do_edit(safe_path, old_text, new_text)

      {:error, :sandbox_violation} ->
        {:error, PathSandbox.violation_message(file, sandbox)}
    end
  end

  def execute(%{"file" => _, "old_text" => _, "new_text" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{file: _, old_text: _, new_text: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp do_edit(file_path, old_text, new_text) do
    case File.read(file_path) do
      {:ok, content} ->
        perform_replacement(file_path, content, old_text, new_text)

      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp perform_replacement(file_path, content, old_text, new_text) do
    # STUTTER DETECTION: Catch "no-op" edits where the model sends identical text
    if normalize_whitespace(old_text) == normalize_whitespace(new_text) do
      {:error, """
      NO CHANGES DETECTED: You provided identical text for old_text and new_text.

      This is a "stutter" - you decided to act but didn't actually change anything.
      Please provide the ACTUAL optimized/refactored code in new_text.

      If you don't know how to improve it, use 'respond' to explain why.
      """}
    else
      # Count occurrences
      count = count_occurrences(content, old_text)

      cond do
        count == 0 ->
          # Not found - try to help
          suggest_similar(content, old_text)

        count > 1 ->
          {:error, "Found #{count} occurrences of old_text. Please provide more context to make it unique."}

        true ->
          # Exactly one match - perform replacement
          new_content = String.replace(content, old_text, new_text, global: false)

          case File.write(file_path, new_content) do
            :ok ->
              {:ok, "Successfully edited #{Path.basename(file_path)}"}

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end
      end
    end
  end

  # Normalize whitespace for comparison (catches near-identical "stutters")
  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp suggest_similar(content, old_text) do
    # Get the first line of old_text for searching
    first_line = old_text
    |> String.split("\n")
    |> List.first()
    |> String.trim()

    if String.length(first_line) > 10 do
      # Search for partial matches
      lines = String.split(content, "\n")
      matches = lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        String.jaro_distance(String.trim(line), first_line) > 0.7
      end)
      |> Enum.take(3)

      if matches != [] do
        suggestions = Enum.map_join(matches, "\n", fn {line, num} ->
          "  Line #{num}: #{String.slice(line, 0, 60)}..."
        end)
        {:error, "old_text not found. Similar lines:\n#{suggestions}"}
      else
        {:error, "old_text not found in file. Please verify the exact text."}
      end
    else
      {:error, "old_text not found in file. Please verify the exact text."}
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
