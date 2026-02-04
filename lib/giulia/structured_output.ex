defmodule Giulia.StructuredOutput do
  @moduledoc """
  Validates LLM responses against Ecto schemas without C dependencies.

  Uses Jason (pure Elixir fallback) for JSON parsing and Ecto changesets
  for validation. This replaces InstructorEx with zero native dependencies.

  Includes robust JSON extraction for small models (3B) that often:
  - Add preamble like "Sure! Here's the JSON:"
  - Forget to close brackets
  - Include markdown code fences
  """

  @doc """
  Parse a JSON string and validate against an Ecto schema module.

  The schema module must implement a `changeset/1` function.
  Automatically extracts JSON from model output that includes preamble.
  """
  def parse(raw_string, schema_module) do
    with {:ok, json_string} <- extract_json(raw_string),
         {:ok, data} <- Jason.decode(json_string),
         changeset = schema_module.changeset(data),
         {:ok, struct} <- apply_changeset(changeset) do
      {:ok, struct}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_decode, Exception.message(error)}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:validation, format_errors(changeset)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extract JSON from raw model output.

  Handles common small-model issues:
  - Preamble text before JSON ("Sure! Here's the JSON:")
  - Markdown code fences (```json ... ```)
  - <action> tags (our preferred format for 3B models)
  - Trailing text after JSON
  - Nested JSON objects
  """
  def extract_json(raw_string) when is_binary(raw_string) do
    cleaned = raw_string
    |> String.trim()
    |> strip_action_tags()
    |> strip_markdown_fences()

    # Try to find JSON object or array
    case find_json_bounds(cleaned) do
      {:ok, json} -> {:ok, json}
      :error -> try_repair_json(cleaned)
    end
  end

  defp strip_action_tags(str) do
    # Extract content from <action>...</action> tags if present
    # Note: Stop sequence may cut off the closing </action> tag, so handle both cases
    cond do
      # Full tags present
      match = Regex.run(~r/<action>\s*(.*?)\s*<\/action>/s, str) ->
        [_, content] = match
        content

      # Opening tag only (stop sequence cut off closing tag)
      match = Regex.run(~r/<action>\s*(.*)/s, str) ->
        [_, content] = match
        String.trim(content)

      # No tags
      true ->
        str
    end
  end

  defp strip_markdown_fences(str) do
    str
    |> String.replace(~r/```json\s*/i, "")
    |> String.replace(~r/```\s*$/, "")
    |> String.replace(~r/^```\s*/, "")
    |> String.trim()
  end

  defp find_json_bounds(str) do
    # Find first { or [ and match to closing bracket
    cond do
      match = Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, str) ->
        {:ok, List.first(match)}

      match = Regex.run(~r/\[[^\[\]]*(?:\[[^\[\]]*\][^\[\]]*)*\]/s, str) ->
        {:ok, List.first(match)}

      true ->
        :error
    end
  end

  defp try_repair_json(str) do
    # Try to find start of JSON and attempt repair
    case Regex.run(~r/\{/, str, return: :index) do
      [{start, _}] ->
        json_attempt = String.slice(str, start..-1//1)
        # Count braces and try to close
        open = count_char(json_attempt, ?{)
        close = count_char(json_attempt, ?})

        if open > close do
          repaired = json_attempt <> String.duplicate("}", open - close)
          {:ok, repaired}
        else
          {:ok, json_attempt}
        end

      nil ->
        {:error, :no_json_found}
    end
  end

  defp count_char(str, char) do
    str |> String.to_charlist() |> Enum.count(&(&1 == char))
  end

  @doc """
  Parse a map (already decoded) and validate against an Ecto schema module.
  """
  def parse_map(data, schema_module) when is_map(data) do
    changeset = schema_module.changeset(data)
    apply_changeset(changeset)
  end

  @doc """
  Validate tool arguments from LLM response against the appropriate schema.
  """
  def validate_tool_call(%{name: name, arguments: args}) do
    schema_module = tool_schema(name)

    if schema_module do
      parse_map(args, schema_module)
    else
      {:error, {:unknown_tool, name}}
    end
  end

  # Map tool names to their schema modules
  defp tool_schema("read_file"), do: Giulia.Tools.ReadFile
  defp tool_schema("write_file"), do: Giulia.Tools.WriteFile
  defp tool_schema("edit_file"), do: Giulia.Tools.EditFile
  defp tool_schema("list_files"), do: Giulia.Tools.ListFiles
  defp tool_schema("get_function"), do: Giulia.Tools.GetFunction
  defp tool_schema("get_module_info"), do: Giulia.Tools.GetModuleInfo
  defp tool_schema("get_context"), do: Giulia.Tools.GetContext
  defp tool_schema("search_code"), do: Giulia.Tools.SearchCode
  defp tool_schema("run_mix"), do: Giulia.Tools.RunMix
  defp tool_schema("respond"), do: Giulia.Tools.Respond
  defp tool_schema("think"), do: Giulia.Tools.Think
  defp tool_schema(_), do: nil

  defp apply_changeset(%Ecto.Changeset{valid?: true} = changeset) do
    {:ok, Ecto.Changeset.apply_changes(changeset)}
  end

  defp apply_changeset(%Ecto.Changeset{} = changeset) do
    {:error, changeset}
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
