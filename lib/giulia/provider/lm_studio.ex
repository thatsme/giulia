defmodule Giulia.Provider.LMStudio do
  @moduledoc """
  LM Studio / OpenAI-compatible local provider.

  For sub-second micro-tasks using small models (Qwen 2.5 Coder 3B).
  LM Studio exposes an OpenAI-compatible endpoint at localhost:1234.

  Docker-Aware: When running in a container, automatically uses
  host.docker.internal to reach the host's LM Studio.

  Use cases:
  - Format this file
  - Generate a docstring
  - Suggest a variable name
  - Summarize an AST node
  - Quick error explanation

  NOT for:
  - Complex architectural changes
  - Multi-file refactoring
  - Debugging race conditions
  """
  @behaviour Giulia.Provider

  @default_model "qwen2.5-coder-7b-instruct"

  # Get URL via PathMapper (handles env var + Docker detection)
  # NO HARDCODED URLS - see CLAUDE.md
  defp default_url do
    Giulia.Core.PathMapper.lm_studio_url()
  end

  @impl true
  def chat(messages, opts \\ []) do
    chat(messages, [], opts)
  end

  @impl true
  def chat(messages, tools, opts) do
    url = opts[:base_url] || Application.get_env(:giulia, :lm_studio_url) || default_url()
    model = opts[:model] || Application.get_env(:giulia, :lm_studio_model, @default_model)
    # LM Studio doesn't require a real key, but we keep header logic consistent
    api_key = opts[:api_key] || Application.get_env(:giulia, :lm_studio_api_key, "lm-studio")

    body = build_request_body(messages, tools, model, opts)

    # Debug: log the URL being used
    require Logger
    Logger.info("LM Studio request to: #{url}")

    case Req.post(url,
           json: body,
           headers: [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/json"}
           ],
           connect_options: [timeout: 60_000],
           pool_timeout: 60_000,
           receive_timeout: opts[:timeout] || 300_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :lm_studio_not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(messages, opts) do
    url = opts[:base_url] || Application.get_env(:giulia, :lm_studio_url) || default_url()
    model = opts[:model] || Application.get_env(:giulia, :lm_studio_model, @default_model)
    api_key = opts[:api_key] || Application.get_env(:giulia, :lm_studio_api_key, "lm-studio")

    body =
      build_request_body(messages, [], model, opts)
      |> Map.put("stream", true)

    stream =
      Req.post!(url,
        json: body,
        headers: [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ],
        into: :self,
        connect_options: [timeout: 30_000],
           receive_timeout: opts[:timeout] || 90_000
      )
      |> stream_events()

    {:ok, stream}
  end

  defp build_request_body(messages, tools, model, opts) do
    body = %{
      "model" => model,
      "messages" => format_messages(messages),
      "temperature" => opts[:temperature] || 0.1,
      "max_tokens" => opts[:max_tokens] || 1024,
      # THE MUZZLE: Stop sequences prevent the 3B model from hallucinating tool results
      # The model MUST stop after </action> - no roleplaying allowed
      "stop" => ["</action>", "[TOOL_RESULT]", "[END_TOOL_RESULT]", "\n\n[TOOL"]
    }

    if tools != [] do
      Map.merge(body, %{
        "tools" => format_tools(tools),
        "tool_choice" => "auto"
      })
    else
      body
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{"role" => to_string(msg.role), "content" => msg.content}
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

  defp parse_response(%{"choices" => [choice | _]}) do
    message = choice["message"]
    tool_calls = parse_tool_calls(message["tool_calls"])
    finish_reason = choice["finish_reason"]

    %{
      content: message["content"],
      tool_calls: tool_calls,
      stop_reason: parse_stop_reason(finish_reason, tool_calls)
    }
  end

  defp parse_response(other) do
    %{
      content: inspect(other),
      tool_calls: [],
      stop_reason: :error
    }
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        name: tc["function"]["name"],
        arguments: parse_arguments(tc["function"]["arguments"])
      }
    end)
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{"raw" => args}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp parse_stop_reason(_, [_ | _]), do: :tool_use
  defp parse_stop_reason("stop", _), do: :end_turn
  defp parse_stop_reason("length", _), do: :max_tokens
  defp parse_stop_reason("tool_calls", _), do: :tool_use
  defp parse_stop_reason(_, _), do: :end_turn

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
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      json = String.replace_prefix(line, "data: ", "")

      if json == "[DONE]" do
        :done
      else
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          {:error, _} -> nil
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
