defmodule Giulia.Inference.ResponseParser do
  @moduledoc """
  Model response parsing for the OODA loop.

  Parses LLM responses into structured tool calls, handling:
  - Native tool_calls from providers (Anthropic, etc.)
  - Hybrid <action>/<payload> format (Groq, Gemini)
  - JSON extraction from raw text
  - Multi-action batched responses
  - Plain text cleanup for final responses

  Pure-functional module — no GenServer coupling.
  """

  require Logger

  alias Giulia.StructuredOutput
  alias Giulia.StructuredOutput.Parser

  @doc """
  Parse a model response into a structured result.

  Returns:
    - `{:tool_call, tool_name, params}` — single tool call
    - `{:multi_tool_call, tool_name, params, remaining}` — batched actions
    - `{:text, content}` — plain text (no tool call found)
    - `{:error, reason}` — parse failure
  """
  def parse(%{content: nil}), do: {:error, :empty_response}

  def parse(%{tool_calls: [tc | _]}) do
    {:tool_call, tc.name, tc.arguments}
  end

  def parse(%{content: content}) when is_binary(content) do
    Logger.info("Raw model response: #{String.slice(content, 0, 300)}")

    if Parser.hybrid_format?(content) or String.contains?(content, "<action>") do
      action_count = length(Regex.scan(~r/<action>/, content))

      if action_count > 1 do
        case Parser.parse_all_actions(content) do
          {:ok, [first | rest]} ->
            Logger.info(
              "Parsed #{action_count} batched actions via Parser (executing sequentially)"
            )

            {:multi_tool_call, first["tool"], first["parameters"], rest}

          {:error, reason} ->
            Logger.warning("Multi-action parse failed (#{inspect(reason)}), trying single")
            parse_single_action(content)
        end
      else
        parse_single_action(content)
      end
    else
      parse_json(content)
    end
  end

  def parse(_), do: {:error, :unknown_response_format}

  @doc """
  Parse a single <action> block from hybrid format content.
  Falls back to JSON parsing on failure.
  """
  def parse_single_action(content) do
    case Parser.parse_response(content) do
      {:ok, %{"tool" => tool, "parameters" => params}} ->
        Logger.info("Parsed via hybrid Parser: tool=#{tool}")
        {:tool_call, tool, params}

      {:error, reason} ->
        Logger.warning("Hybrid parse failed (#{inspect(reason)}), falling back to JSON path")
        parse_json(content)
    end
  end

  @doc """
  JSON-only parsing path for model responses.
  """
  def parse_json(content) do
    case StructuredOutput.extract_json(content) do
      {:ok, json} ->
        clean_json = String.trim(json)
        Logger.info("Extracted JSON (#{byte_size(clean_json)} bytes): #{clean_json}")

        case Jason.decode(clean_json) do
          {:ok, %{"tool" => tool, "parameters" => params}} ->
            {:tool_call, tool, params}

          {:ok, %{"tool" => tool}} ->
            Logger.warning("Tool call missing parameters: #{tool}")
            {:tool_call, tool, %{}}

          {:ok, decoded} ->
            Logger.warning("Invalid tool format: #{inspect(decoded)}")
            {:error, :invalid_tool_format}

          {:error, %Jason.DecodeError{position: pos} = decode_error} ->
            Logger.warning("JSON decode error at position #{pos}: #{inspect(decode_error)}")
            {:error, {:json_escape_error, pos, clean_json}}

          {:error, decode_error} ->
            Logger.warning("JSON decode error: #{inspect(decode_error)}")
            {:error, {:json_decode_error, decode_error}}
        end

      {:error, reason} ->
        Logger.debug("No JSON found: #{inspect(reason)}")
        {:text, content}
    end
  end

  @doc """
  Clean up model output that contains internal tokens or malformed data.
  """
  def clean_output(text) do
    text
    |> String.replace(~r/<\|im_start\|>.*?(<\|im_end\|>)?/s, "")
    |> String.replace(~r/<\|im_end\|>/, "")
    |> String.replace(~r/<action>.*?<\/action>/s, "")
    |> String.replace(~r/<action>.*$/s, "")
    |> String.replace(~r/<\/?think>/s, "")
    |> String.trim()
    |> case do
      "" -> "I wasn't able to formulate a proper response. Please try rephrasing your request."
      cleaned -> cleaned
    end
  end

  @doc """
  Extract context around a JSON parse error position.
  """
  def extract_error_context(json, position) do
    start_pos = max(0, position - 30)
    end_pos = min(String.length(json), position + 30)
    String.slice(json, start_pos, end_pos - start_pos)
  end
end
