defmodule Giulia.StructuredOutput.Parser do
  @moduledoc """
  Hybrid format parser: separates intent (JSON) from code (raw Elixir).

  The core insight: asking a 3B model to JSON-escape Elixir code is asking
  a probabilistic model to do deterministic work. It fails at escaping
  `\\n`, `"`, backticks — creating cascading JSON decode errors.

  The fix: `<action>` carries JSON intent, code goes in a standard markdown
  fenced block (```elixir ... ```) after `</action>`. Models are trained on
  millions of markdown code fences — it's their natural output format.

  Anti-leak protection: `PatchFunction.parse_new_function/1` validates code
  with `Code.string_to_quoted` before writing. Non-Elixir text causes a
  syntax error that gets fed back to the model for self-correction.

  ## Parsing Strategy (4-tier fallback)

  1. `<action>` + fenced ```elixir block → JSON intent + clean code
  2. `<action>` + raw trailing Elixir  → JSON intent + heuristic code extraction
  3. `<action>` only → extract JSON (non-code tools like read_file, respond)
  4. No tags → fallback to `StructuredOutput.extract_json/1`
  """

  require Logger

  alias Giulia.StructuredOutput

  # Tools that require a "code" parameter
  @code_tools ["patch_function", "write_function"]

  @doc """
  Quick check for hybrid format (contains `<payload>` tag).
  """
  @spec hybrid_format?(String.t()) :: boolean()
  def hybrid_format?(response) when is_binary(response) do
    String.contains?(response, "<payload>")
  end

  def hybrid_format?(_), do: false

  @doc """
  Main entry point. Parse a model response into a tool call map.

  Returns `{:ok, %{"tool" => ..., "parameters" => ...}}` or `{:error, reason}`.
  """
  @spec parse_response(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_response(response) when is_binary(response) do
    cond do
      # Tier 1: Explicit <payload> tags
      hybrid_format?(response) ->
        parse_explicit_payload(response)

      # Tier 2+3: <action> present — check for trailing code after </action>
      String.contains?(response, "<action>") ->
        parse_action_with_trailing_code(response)

      # Tier 4: Plain JSON fallback
      true ->
        parse_plain_json(response)
    end
  end

  def parse_response(_), do: {:error, :not_a_string}

  # ============================================================================
  # Tier 1: Explicit <payload> tags
  # ============================================================================

  defp parse_explicit_payload(response) do
    action_match = Regex.run(~r/<action>\s*(.*?)\s*<\/action>/s, response)
    payload_match = Regex.run(~r/<payload>\s*\n?(.*?)\s*<\/payload>/s, response)

    case {action_match, payload_match} do
      {[_, action_json], [_, raw_code]} ->
        parse_action_json_with_code(action_json, raw_code)

      {nil, _} ->
        Logger.warning("Parser: <payload> found but no <action> tag")
        {:error, :missing_action_tag}

      {_, nil} ->
        # Has <action> but <payload> extraction failed — try trailing code
        Logger.info("Parser: <payload> extraction failed, trying trailing code")
        parse_action_with_trailing_code(response)
    end
  end

  # ============================================================================
  # Tier 2+3: <action> with optional trailing code after </action>
  # ============================================================================

  defp parse_action_with_trailing_code(response) do
    # Extract JSON from <action>...</action>
    case Regex.run(~r/<action>\s*(.*?)\s*<\/action>(.*)/s, response) do
      [_, action_json, trailing] ->
        # Parse the JSON first to get the tool name
        case Jason.decode(String.trim(action_json)) do
          {:ok, %{"tool" => tool, "parameters" => params}} when is_map(params) ->
            # Check if this is a code tool and there's trailing content
            trailing_code = extract_trailing_code(trailing)

            if tool in @code_tools and trailing_code != nil do
              # Tier 2: Code tool with trailing code — inject it
              merged_params = Map.put(params, "code", trailing_code)

              Logger.info(
                "Parser: Action + trailing code — tool=#{tool}, code=#{byte_size(trailing_code)} bytes"
              )

              {:ok, %{"tool" => tool, "parameters" => merged_params}}
            else
              # Tier 3: Non-code tool or no trailing code
              Logger.info("Parser: Action-only format — tool=#{tool}")
              {:ok, %{"tool" => tool, "parameters" => params}}
            end

          {:ok, %{"tool" => tool}} ->
            trailing_code = extract_trailing_code(trailing)

            if tool in @code_tools and trailing_code != nil do
              {:ok, %{"tool" => tool, "parameters" => %{"code" => trailing_code}}}
            else
              {:ok, %{"tool" => tool, "parameters" => %{}}}
            end

          {:ok, other} ->
            {:error, {:invalid_action_format, other}}

          {:error, _decode_error} ->
            Logger.warning("Parser: Action JSON decode failed, trying repair")
            try_repair_action_json(action_json)
        end

      nil ->
        # No closing </action> — try unclosed tag
        parse_unclosed_action(response)
    end
  end

  # Handle unclosed <action> tag (model didn't close it)
  defp parse_unclosed_action(response) do
    case Regex.run(~r/<action>\s*(.*)/s, response) do
      [_, content] ->
        json_str = String.trim(content)

        case Jason.decode(json_str) do
          {:ok, %{"tool" => tool, "parameters" => params}} when is_map(params) ->
            Logger.info("Parser: Unclosed action — tool=#{tool}")
            {:ok, %{"tool" => tool, "parameters" => params}}

          {:ok, %{"tool" => tool}} ->
            {:ok, %{"tool" => tool, "parameters" => %{}}}

          {:error, _} ->
            try_repair_action_json(json_str)
        end

      nil ->
        {:error, :no_action_tag}
    end
  end

  # Extract code from text after </action>
  # Priority: fenced ```elixir block (natural model output) → raw Elixir fallback
  defp extract_trailing_code(trailing) when is_binary(trailing) do
    trimmed = String.trim(trailing)

    cond do
      # Empty — no trailing code
      trimmed == "" ->
        nil

      # Fenced code block: ```elixir\n...\n``` (primary strategy)
      # GREEDY match: (.*)  captures everything, closing ``` must be on its OWN LINE.
      # This handles code that contains literal ``` (e.g. regex patterns with backticks).
      # The mid-line ``` inside code won't match \n``` which requires a newline before it.
      String.contains?(trimmed, "```") ->
        case Regex.run(~r/```(?:elixir|Elixir)?\s*\n(.*)\n```[ \t]*(?:\n|\z)/s, trimmed) do
          [_, code] ->
            clean = String.trim(code)
            if String.length(clean) > 5, do: clean, else: nil

          nil ->
            extract_raw_elixir(trimmed)
        end

      # Raw Elixir fallback (starts with def/defp or other Elixir keywords)
      true ->
        extract_raw_elixir(trimmed)
    end
  end

  defp extract_trailing_code(_), do: nil

  # Extract raw Elixir code — strip non-code preamble
  defp extract_raw_elixir(text) do
    # Find where the actual Elixir code starts
    lines = String.split(text, "\n")

    # Drop leading non-code lines (explanatory text, empty lines)
    code_lines =
      Enum.drop_while(lines, fn line ->
        trimmed = String.trim(line)

        trimmed == "" or
          (not String.starts_with?(trimmed, "def ") and
             not String.starts_with?(trimmed, "defp ") and
             not String.starts_with?(trimmed, "@") and
             not String.starts_with?(trimmed, "def(") and
             not Regex.match?(~r/^\s*(def|defp|defmacro|defguard)\s/, trimmed))
      end)

    case code_lines do
      [] ->
        nil

      _ ->
        code = Enum.join(code_lines, "\n") |> String.trim()
        if String.length(code) > 10, do: code, else: nil
    end
  end

  # ============================================================================
  # Parse action JSON and inject code
  # ============================================================================

  defp parse_action_json_with_code(action_json, raw_code) do
    case Jason.decode(String.trim(action_json)) do
      {:ok, %{"tool" => tool, "parameters" => params}} when is_map(params) ->
        merged_params = Map.put(params, "code", raw_code)

        Logger.info(
          "Parser: Hybrid format parsed — tool=#{tool}, code=#{byte_size(raw_code)} bytes"
        )

        {:ok, %{"tool" => tool, "parameters" => merged_params}}

      {:ok, %{"tool" => tool}} ->
        Logger.info("Parser: Hybrid format (no params) — tool=#{tool}")
        {:ok, %{"tool" => tool, "parameters" => %{"code" => raw_code}}}

      {:ok, other} ->
        Logger.warning("Parser: Hybrid action JSON missing 'tool' key: #{inspect(other)}")
        {:error, {:invalid_action_format, other}}

      {:error, decode_error} ->
        Logger.warning("Parser: Hybrid action JSON decode failed: #{inspect(decode_error)}")
        {:error, {:action_json_decode_error, decode_error}}
    end
  end

  # ============================================================================
  # Tier 4: Plain JSON Fallback
  # ============================================================================

  defp parse_plain_json(response) do
    case StructuredOutput.extract_json(response) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"tool" => tool, "parameters" => params}} when is_map(params) ->
            {:ok, %{"tool" => tool, "parameters" => params}}

          {:ok, %{"tool" => tool}} ->
            {:ok, %{"tool" => tool, "parameters" => %{}}}

          {:ok, _other} ->
            {:error, :invalid_tool_format}

          {:error, decode_error} ->
            {:error, {:json_decode_error, decode_error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Multi-Action Parsing — extract ALL <action> blocks from one response
  # ============================================================================

  @doc """
  Parse ALL action blocks from a model response. Returns a list of parsed tool calls.
  Used when the model batches multiple tool calls in a single response.

  Returns `{:ok, [%{"tool" => ..., "parameters" => ...}, ...]}` or falls back
  to single-action parsing if only one action is found.
  """
  @spec parse_all_actions(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_all_actions(response) when is_binary(response) do
    # Find all <action>...</action> blocks with their trailing content
    # Pattern: each <action>JSON</action> optionally followed by ```elixir code```
    case extract_action_blocks(response) do
      [] -> {:error, :no_actions_found}
      [single] -> {:ok, [single]}
      multiple -> {:ok, multiple}
    end
  end

  defp extract_action_blocks(response) do
    # Split response at each <action> tag
    # Regex captures: (action_json) and (trailing content until next <action> or end)
    pattern = ~r/<action>\s*(.*?)\s*<\/action>(.*?)(?=<action>|\z)/s
    matches = Regex.scan(pattern, response)

    matches
    |> Enum.map(fn [_full, action_json, trailing] ->
      parse_single_action_block(action_json, trailing)
    end)
    |> Enum.filter(fn result -> result != nil end)
  end

  defp parse_single_action_block(action_json, trailing) do
    case Jason.decode(String.trim(action_json)) do
      {:ok, %{"tool" => tool, "parameters" => params}} when is_map(params) ->
        trailing_code = extract_trailing_code(trailing)

        if tool in @code_tools and trailing_code != nil do
          %{"tool" => tool, "parameters" => Map.put(params, "code", trailing_code)}
        else
          %{"tool" => tool, "parameters" => params}
        end

      {:ok, %{"tool" => tool}} ->
        trailing_code = extract_trailing_code(trailing)

        if tool in @code_tools and trailing_code != nil do
          %{"tool" => tool, "parameters" => %{"code" => trailing_code}}
        else
          %{"tool" => tool, "parameters" => %{}}
        end

      _ ->
        nil
    end
  end

  # ============================================================================
  # JSON Repair for Action Tags
  # ============================================================================

  defp try_repair_action_json(json_str) do
    tool_match = Regex.run(~r/"tool"\s*:\s*"([^"]+)"/, json_str)

    case tool_match do
      [_, tool_name] ->
        Logger.info("Parser: Repaired — extracted tool=#{tool_name} from malformed JSON")
        params = extract_partial_params(json_str)
        {:ok, %{"tool" => tool_name, "parameters" => params}}

      nil ->
        {:error, :unrecoverable_json}
    end
  end

  defp extract_partial_params(json_str) do
    params =
      Regex.scan(~r/"(\w+)"\s*:\s*"([^"]*)"/, json_str)
      |> Enum.reject(fn [_, key, _] -> key == "tool" end)
      |> Map.new(fn [_, key, value] -> {key, value} end)

    int_params =
      Regex.scan(~r/"(\w+)"\s*:\s*(\d+)/, json_str)
      |> Map.new(fn [_, key, value] -> {key, elem(Integer.parse(value), 0)} end)

    Map.merge(params, int_params)
  end
end
