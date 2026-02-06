defmodule Giulia.Provider.Gemini do
  @moduledoc """
  Gemini Provider - The Surgical Consultant.

  Called only when the local 14B model fails to fix syntax errors.
  Uses Gemini 1.5 Pro with JSON mode for precise, parseable responses.

  This is NOT for general chat - it's for emergency escalation.
  """

  @behaviour Giulia.Provider

  require Logger

  # Gemini 2.0 Flash - has free tier quota and good reasoning
  @default_model "gemini-2.0-flash"
  @base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def chat(messages, _tools, opts \\ []) do
    api_key = System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      timeout = Keyword.get(opts, :timeout, 60_000)
      url = "#{@base_url}/#{model}:generateContent?key=#{api_key}"

      # Use JSON mode for structured surgical responses
      json_mode = Keyword.get(opts, :json_mode, false)

      generation_config = %{
        temperature: 0.0,
        maxOutputTokens: 4096
      }

      # Add responseMimeType for JSON mode if requested
      generation_config = if json_mode do
        Map.put(generation_config, :responseMimeType, "application/json")
      else
        generation_config
      end

      body = %{
        contents: format_messages(messages),
        generationConfig: generation_config
      }

      Logger.info("=== GEMINI ESCALATION CALL ===")
      Logger.info("Model: #{model}")
      Logger.info("JSON Mode: #{json_mode}")
      Logger.debug("Request body: #{inspect(body, pretty: true, limit: 500)}")

      case Req.post(url, json: body, receive_timeout: timeout) do
        {:ok, %{status: 200, body: resp}} ->
          # LOG THE RAW RESPONSE so we can inspect it
          Logger.info("=== GEMINI RAW RESPONSE ===")
          Logger.info("#{inspect(resp, pretty: true, limit: 5000)}")
          Logger.info("=== END GEMINI RESPONSE ===")
          parse_response(resp)

        {:ok, %{status: status, body: body}} ->
          Logger.error("Gemini API error: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Gemini request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def stream(_messages, _tools) do
    # Gemini is only used for escalation, not streaming
    {:error, :streaming_not_supported}
  end

  # Not part of behaviour, but useful for checking availability
  def available? do
    api_key = System.get_env("GEMINI_API_KEY")
    not is_nil(api_key) and api_key != ""
  end

  # Format Elixir messages to Gemini's nested structure
  # Gemini expects: %{contents: [%{role: "user", parts: [%{text: "..."}]}]}
  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = normalize_role(msg[:role] || msg["role"])
      content = msg[:content] || msg["content"]

      %{
        role: role,
        parts: [%{text: content}]
      }
    end)
  end

  # Gemini only accepts "user" and "model" roles
  defp normalize_role("system"), do: "user"  # Prepend system as user message
  defp normalize_role("assistant"), do: "model"
  defp normalize_role("user"), do: "user"
  defp normalize_role(other), do: other

  # Parse Gemini's response structure
  defp parse_response(%{"candidates" => [first | _]}) do
    case first do
      %{"content" => %{"parts" => [%{"text" => text} | _]}} ->
        {:ok, %{content: text, tool_calls: nil}}

      %{"content" => %{"parts" => parts}} when is_list(parts) ->
        text = Enum.map_join(parts, "\n", fn
          %{"text" => t} -> t
          _ -> ""
        end)
        {:ok, %{content: text, tool_calls: nil}}

      _ ->
        {:error, :unexpected_response_format}
    end
  end

  defp parse_response(%{"error" => error}) do
    {:error, {:gemini_error, error}}
  end

  defp parse_response(other) do
    Logger.warning("Unexpected Gemini response: #{inspect(other)}")
    {:error, :unexpected_response}
  end
end
