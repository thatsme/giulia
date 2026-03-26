defmodule Giulia.Provider.Anthropic do
  @moduledoc """
  Anthropic Claude API provider.

  Uses Req for HTTP requests. Designed for work mode with cloud API.
  """
  @behaviour Giulia.Provider

  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"
  @max_tokens 4096

  @impl true
  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    chat(messages, [], opts)
  end

  @impl true
  @spec chat(list(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, tools, opts) do
    api_key = opts[:api_key] || Application.get_env(:giulia, :anthropic_api_key)

    unless api_key do
      {:error, :missing_api_key}
    else
      body = build_request_body(messages, tools, opts)

      case Req.post(@api_url,
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"},
               {"content-type", "application/json"}
             ],
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, parse_response(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  @spec stream(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def stream(messages, opts) do
    api_key = opts[:api_key] || Application.get_env(:giulia, :anthropic_api_key)

    unless api_key do
      {:error, :missing_api_key}
    else
      body =
        Map.put(build_request_body(messages, [], opts), "stream", true)

      stream =
        stream_events(Req.post!(@api_url,
          json: body,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"},
            {"content-type", "application/json"}
          ],
          into: :self
        ))

      {:ok, stream}
    end
  end

  defp build_request_body(messages, tools, opts) do
    {system_msg, chat_messages} = extract_system_message(messages)

    body = %{
      "model" => opts[:model] || @model,
      "max_tokens" => opts[:max_tokens] || @max_tokens,
      "messages" => format_messages(chat_messages)
    }

    body = if system_msg, do: Map.put(body, "system", system_msg), else: body
    body = if tools != [], do: Map.put(body, "tools", format_tools(tools)), else: body

    body
  end

  defp extract_system_message(messages) do
    case Enum.split_with(messages, &(&1.role == "system")) do
      {[%{content: system} | _], rest} -> {system, rest}
      {[], messages} -> {nil, messages}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{"role" => msg.role, "content" => msg.content}
    end)
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.parameters
      }
    end)
  end

  @doc false
  @spec parse_response(map()) :: map()
  def parse_response(%{"content" => content, "stop_reason" => stop_reason}) do
    {text_content, tool_calls} =
      Enum.reduce(content, {nil, []}, fn
        %{"type" => "text", "text" => text}, {_, tools} ->
          {text, tools}

        %{"type" => "tool_use", "name" => name, "input" => input, "id" => id}, {text, tools} ->
          {text, [%{id: id, name: name, arguments: input} | tools]}

        _, acc ->
          acc
      end)

    %{
      content: text_content,
      tool_calls: Enum.reverse(tool_calls),
      stop_reason: parse_stop_reason(stop_reason)
    }
  end

  @doc false
  def parse_response(other) do
    %{
      content: inspect(other),
      tool_calls: [],
      stop_reason: :error
    }
  end

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason(nil), do: :unknown
  defp parse_stop_reason(other) when is_binary(other) do
    # Use to_existing_atom to prevent atom table exhaustion from untrusted input.
    # Falls back to :unknown for unrecognized stop reasons.
    try do
      String.to_existing_atom(other)
    rescue
      ArgumentError -> :unknown
    end
  end
  defp parse_stop_reason(_other), do: :unknown

  defp stream_events(%Req.Response{} = resp) do
    Stream.resource(
      fn -> resp end,
      fn resp ->
        receive do
          {_ref, {:data, data}} ->
            events = parse_sse_events(data)
            {events, resp}

          {_ref, :done} ->
            {:halt, resp}
        after
          30_000 -> {:halt, resp}
        end
      end,
      fn _resp -> :ok end
    )
  end

  defp parse_sse_events(data) do
    data
    |> String.split("\n\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      line
      |> String.replace_prefix("data: ", "")
      |> Jason.decode!()
    end)
  end
end
