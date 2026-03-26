defmodule Giulia.Provider.Ollama do
  @moduledoc """
  Ollama local LLM provider.

  Uses Req for HTTP requests. Designed for home mode with local Qwen 32B.
  """
  @behaviour Giulia.Provider

  @impl true
  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    chat(messages, [], opts)
  end

  @impl true
  @spec chat(list(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, tools, opts) do
    base_url = opts[:base_url] || Application.get_env(:giulia, :ollama_base_url)
    model = opts[:model] || Application.get_env(:giulia, :ollama_model)

    body = build_request_body(messages, tools, model, opts)

    case Req.post("#{base_url}/api/chat", json: body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec stream(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def stream(messages, opts) do
    base_url = opts[:base_url] || Application.get_env(:giulia, :ollama_base_url)
    model = opts[:model] || Application.get_env(:giulia, :ollama_model)

    body =
      Map.put(build_request_body(messages, [], model, opts), "stream", true)

    stream =
      stream_events(Req.post!("#{base_url}/api/chat",
        json: body,
        into: :self
      ))

    {:ok, stream}
  end

  defp build_request_body(messages, tools, model, _opts) do
    body = %{
      "model" => model,
      "messages" => format_messages(messages),
      "stream" => false
    }

    if tools != [] do
      Map.put(body, "tools", format_tools(tools))
    else
      body
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
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp parse_response(%{"message" => message, "done" => true}) do
    tool_calls =
      case message do
        %{"tool_calls" => calls} when is_list(calls) ->
          Enum.map(calls, fn call ->
            %{
              name: call["function"]["name"],
              arguments: call["function"]["arguments"]
            }
          end)

        _ ->
          []
      end

    %{
      content: message["content"],
      tool_calls: tool_calls,
      stop_reason: if(tool_calls != [], do: :tool_use, else: :end_turn)
    }
  end

  defp stream_events(%Req.Response{} = resp) do
    Stream.resource(
      fn -> resp end,
      fn resp ->
        receive do
          {_ref, {:data, data}} ->
            events =
              data
              |> String.split("\n")
              |> Enum.filter(&(&1 != ""))
              |> Enum.map(&Jason.decode!/1)

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
end
