defmodule Giulia.StructuredOutput do
  @moduledoc "Validates LLM responses against Ecto schemas without C dependencies.\r\n\r\nUses Jason (pure Elixir fallback) for JSON parsing and Ecto changesets\r\nfor validation. This replaces InstructorEx with zero native dependencies.\r\n\r\nIncludes robust JSON extraction for small models (3B) that often:\r\n- Add preamble like \"Sure! Here's the JSON:\"\r\n- Forget to close brackets\r\n- Include markdown code fences\r\n"
  @doc "Parse a JSON string and validate against an Ecto schema module.\r\n\r\nThe schema module must implement a `changeset/1` function.\r\nAutomatically extracts JSON from model output that includes preamble.\r\n"
  def parse(raw_string, schema_module) do
    with {:ok, json_string} <- extract_json(raw_string),
         {:ok, data} <- Jason.decode(json_string),
         changeset = schema_module.changeset(data),
         {:ok, struct} <- apply_changeset(changeset) do
      {:ok, struct}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:json_decode, Exception.message(error)}}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:validation, format_errors(changeset)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Extract JSON from raw model output.\r\n\r\nHandles common small-model issues:\r\n- Preamble text before JSON (\"Sure! Here's the JSON:\")\r\n- Markdown code fences (```json ... ```)\r\n- <action> tags (our preferred format for 3B models)\r\n- Trailing text after JSON\r\n- Nested JSON objects\r\n"
  def extract_json(raw_string) when is_binary(raw_string) do
    cleaned = raw_string |> String.trim() |> strip_action_tags() |> strip_markdown_fences()

    case find_json_bounds(cleaned) do
      {:ok, json} -> {:ok, json}
      :error -> try_repair_json(cleaned)
    end
  end

  defp strip_action_tags(str) do
    cond do
      match = Regex.run(~r/<action>\s*(.*?)\s*<\/action>/s, str) ->
        [_, content] = match
        content

      match = Regex.run(~r/<action>\s*(.*)/s, str) ->
        [_, content] = match
        String.trim(content)

      true ->
        str
    end
  end

  defp strip_markdown_fences(str) do
    Regex.replace(~r/(^|\n)```[a-z]*\n?(.*?)\n?```(\n|$)/s, str, "\\2")
  end

  defp find_json_bounds(str) do
    case Jason.decode(str) do
      {:ok, _} -> {:ok, str}
      {:error, _} -> find_json_with_regex(str)
    end
  end

  defp find_json_with_regex(str) do
    case Regex.run(~r/\{/, str, return: :index) do
      [{start, _}] ->
        json_str = String.slice(str, start..-1//1)
        find_matching_brace(json_str, 0, 0, false, 0)

      nil ->
        case Regex.run(~r/\[/, str, return: :index) do
          [{start, _}] -> {:ok, String.slice(str, start..-1//1)}
          nil -> :error
        end
    end
  end

  defp find_matching_brace(str, pos, depth, in_string, escape_next) do
    case String.at(str, pos) do
      nil ->
        if depth > 0 do
          :error
        else
          {:ok, str}
        end

      char ->
        cond do
          escape_next ->
            find_matching_brace(str, pos + 1, depth, in_string, false)

          char == "\\" and in_string ->
            find_matching_brace(str, pos + 1, depth, in_string, true)

          char == "\"" ->
            find_matching_brace(str, pos + 1, depth, not in_string, false)

          char == "{" and not in_string ->
            find_matching_brace(str, pos + 1, depth + 1, in_string, false)

          char == "}" and not in_string ->
            if depth == 1 do
              {:ok, String.slice(str, 0, pos + 1)}
            else
              find_matching_brace(str, pos + 1, depth - 1, in_string, false)
            end

          true ->
            find_matching_brace(str, pos + 1, depth, in_string, false)
        end
    end
  end

  # Single-pass string-aware JSON repair using binary pattern matching
  # This is the "Father Killer" - handles braces inside strings correctly
  defp try_repair_json(str) do
    case str do
      <<"{"::utf8, _rest::binary>> ->
        # Count braces with string awareness in a single pass
        {open, close} = count_braces(str, 0, 0, false, false)

        if open > close do
          repaired = str <> String.duplicate("}", open - close)
          {:ok, repaired}
        else
          {:ok, str}
        end

      _ ->
        {:error, :no_json_found}
    end
  end

  # Single-pass recursive scanner with string tracking
  # O(N) time, O(1) memory (tail recursive with sub-binaries)
  defp count_braces(<<>>, open, close, _in_string, _escape), do: {open, close}

  # Handle escape sequences inside strings
  defp count_braces(<<"\\", _::utf8, rest::binary>>, open, close, true, _escape) do
    count_braces(rest, open, close, true, false)
  end

  # Toggle string state on unescaped quotes
  defp count_braces(<<"\"", rest::binary>>, open, close, in_string, false) do
    count_braces(rest, open, close, not in_string, false)
  end

  # Count braces ONLY when not inside a string
  defp count_braces(<<"{", rest::binary>>, open, close, false, _escape) do
    count_braces(rest, open + 1, close, false, false)
  end

  defp count_braces(<<"}", rest::binary>>, open, close, false, _escape) do
    count_braces(rest, open, close + 1, false, false)
  end

  # Skip all other characters
  defp count_braces(<<_::utf8, rest::binary>>, open, close, in_string, _escape) do
    count_braces(rest, open, close, in_string, false)
  end

  @doc "Parse a map (already decoded) and validate against an Ecto schema module.\r\n"
  def parse_map(data, schema_module) when is_map(data) do
    changeset = schema_module.changeset(data)
    apply_changeset(changeset)
  end

  @doc "Validate tool arguments from LLM response against the appropriate schema.\r\n"
  def validate_tool_call(%{name: name, arguments: args}) do
    schema_module = tool_schema(name)

    if schema_module do
      parse_map(args, schema_module)
    else
      {:error, {:unknown_tool, name}}
    end
  end

  defp tool_schema("read_file") do
    Giulia.Tools.ReadFile
  end

  defp tool_schema("write_file") do
    Giulia.Tools.WriteFile
  end

  defp tool_schema("edit_file") do
    Giulia.Tools.EditFile
  end

  defp tool_schema("list_files") do
    Giulia.Tools.ListFiles
  end

  defp tool_schema("get_function") do
    Giulia.Tools.GetFunction
  end

  defp tool_schema("get_module_info") do
    Giulia.Tools.GetModuleInfo
  end

  defp tool_schema("get_context") do
    Giulia.Tools.GetContext
  end

  defp tool_schema("search_code") do
    Giulia.Tools.SearchCode
  end

  defp tool_schema("run_mix") do
    Giulia.Tools.RunMix
  end

  defp tool_schema("respond") do
    Giulia.Tools.Respond
  end

  defp tool_schema("think") do
    Giulia.Tools.Think
  end

  defp tool_schema(_) do
    nil
  end

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
