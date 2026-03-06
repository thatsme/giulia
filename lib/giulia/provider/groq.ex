defmodule Giulia.Provider.Groq do
  @moduledoc """
  Groq Provider - LPU-accelerated inference for escalation.

  Uses Llama 3.3 70B for surgical syntax fixes.
  Blazing fast, generous free tier - the Victory move.
  """

  @behaviour Giulia.Provider

  require Logger

  @default_model "llama-3.3-70b-versatile"
  @base_url "https://api.groq.com/openai/v1/chat/completions"

  @impl true
  def chat(messages, opts) when is_list(opts) do
    chat(messages, [], opts)
  end

  @impl true
  def chat(messages, _tools, opts) do
    api_key = System.get_env("GROQ_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      timeout = Keyword.get(opts, :timeout, 60_000)

      body = %{
        model: model,
        messages: format_messages(messages),
        temperature: 0.0,
        max_tokens: 32768  # Llama 3.3 70B supports up to 128k context
      }

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      Logger.info("=== GROQ ESCALATION CALL ===")
      Logger.info("Model: #{model}")
      Logger.debug("Request body: #{inspect(body, pretty: true, limit: 500)}")

      case Req.post(@base_url, json: body, headers: headers, receive_timeout: timeout) do
        {:ok, %{status: 200, body: resp}} ->
          Logger.info("=== GROQ RAW RESPONSE ===")
          Logger.info("#{inspect(resp, pretty: true, limit: 5000)}")
          Logger.info("=== END GROQ RESPONSE ===")
          parse_response(resp)

        {:ok, %{status: status, body: body}} ->
          Logger.error("Groq API error: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Groq request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def stream(_messages, _opts) do
    {:error, :streaming_not_supported}
  end

  def available? do
    api_key = System.get_env("GROQ_API_KEY")
    not is_nil(api_key) and api_key != ""
  end

  # Format messages for OpenAI-compatible API
  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: msg[:role] || msg["role"],
        content: msg[:content] || msg["content"]
      }
    end)
  end

  @doc false
  def parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, %{content: content, tool_calls: nil}}
  end

  @doc false
  def parse_response(%{"error" => error}) do
    {:error, {:groq_error, error}}
  end

  @doc false
  def parse_response(other) do
    Logger.warning("Unexpected Groq response: #{inspect(other)}")
    {:error, :unexpected_response}
  end
end
