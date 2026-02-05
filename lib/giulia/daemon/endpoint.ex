defmodule Giulia.Daemon.Endpoint do
  @moduledoc """
  HTTP API endpoint for the Giulia daemon.

  Replaces Erlang distribution with simple HTTP/JSON - works reliably
  across Docker boundaries without EPMD drama.
  """

  use Plug.Router

  plug Plug.Logger
  plug :match
  plug :fetch_query_params
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  # Health check
  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{
      status: "ok",
      node: node(),
      version: Giulia.Version.short_version()
    }))
  end

  # Streaming command endpoint (SSE for real-time OODA steps)
  post "/api/command/stream" do
    case conn.body_params do
      %{"message" => message, "path" => path} ->
        resolved_path = Giulia.Core.PathMapper.resolve_path(path)

        case Giulia.Core.ContextManager.get_context(resolved_path) do
          {:ok, context_pid} ->
            # Generate request ID and subscribe
            request_id = make_ref() |> inspect()
            Giulia.Inference.Events.subscribe(request_id)

            # Start SSE response
            conn = conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

            # Send initial event
            {:ok, conn} = chunk(conn, "event: start\ndata: {\"request_id\": \"#{request_id}\"}\n\n")

            # Execute inference async
            spawn(fn ->
              execute_inference_streaming(message, resolved_path, context_pid, request_id)
            end)

            # Stream events
            stream_events(conn, request_id)

          {:needs_init, _} ->
            send_json(conn, 200, %{status: "needs_init", message: "No GIULIA.md found."})

          {:error, reason} ->
            send_json(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        send_json(conn, 400, %{error: "Missing required fields"})
    end
  end

  # Main command endpoint
  post "/api/command" do
    case conn.body_params do
      %{"command" => command, "path" => path} ->
        # Path mapping handled in handle_command for command-specific logic
        result = handle_command(command, path, conn.body_params)
        send_json(conn, 200, result)

      %{"message" => message, "path" => path} ->
        # Path mapping handled in handle_chat
        result = handle_chat(message, path)
        send_json(conn, 200, result)

      _ ->
        send_json(conn, 400, %{error: "Missing required fields: command/message and path"})
    end
  end

  # Status endpoint
  get "/api/status" do
    status = %{
      node: node(),
      started_at: Application.get_env(:giulia, :started_at, DateTime.utc_now()),
      uptime_seconds: 0,
      active_projects: length(Giulia.Core.ContextManager.list_projects())
    }
    send_json(conn, 200, status)
  end

  # List projects
  get "/api/projects" do
    projects = Giulia.Core.ContextManager.list_projects()
    send_json(conn, 200, %{projects: projects})
  end

  # Index query - Pure Elixir, no LLM needed
  # "What modules do I have?" -> Direct from ETS
  get "/api/index/modules" do
    modules = Giulia.Context.Store.list_modules()
    send_json(conn, 200, %{modules: modules, count: length(modules)})
  end

  # "What functions are in module X?"
  # Supports ?module=Giulia.StructuredOutput query param
  get "/api/index/functions" do
    module_filter = conn.query_params["module"]
    functions = Giulia.Context.Store.list_functions(module_filter)
    send_json(conn, 200, %{functions: functions, count: length(functions), module: module_filter})
  end

  # Project summary - The "distilled metadata" for small models
  get "/api/index/summary" do
    summary = Giulia.Context.Store.project_summary()
    send_json(conn, 200, %{summary: summary})
  end

  # Indexer status
  get "/api/index/status" do
    status = Giulia.Context.Indexer.status()
    send_json(conn, 200, status)
  end

  # Trigger a re-index for a project path
  post "/api/index/scan" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    Giulia.Context.Indexer.scan(resolved_path)
    send_json(conn, 200, %{status: "scanning", path: resolved_path})
  end

  # Debug: Show current path mappings
  get "/api/debug/paths" do
    mappings = Giulia.Core.PathMapper.list_mappings()
    in_container = Giulia.Core.PathMapper.in_container?()

    send_json(conn, 200, %{
      in_container: in_container,
      mappings: Enum.map(mappings, fn {host, container} ->
        %{host: host, container: container}
      end)
    })
  end

  # Debug: Last inference trace (The Architect's "Black Box")
  get "/api/agent/last_trace" do
    case Giulia.Inference.Trace.get_last() do
      nil ->
        send_json(conn, 200, %{trace: nil, message: "No inference has run yet"})

      trace ->
        send_json(conn, 200, %{trace: trace})
    end
  end

  # Initialize project
  post "/api/init" do
    path = conn.body_params["path"]
    opts = conn.body_params["opts"] || %{}

    # Map host path to container path if running in Docker
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.init_project(resolved_path, opts) do
      {:ok, _} ->
        send_json(conn, 200, %{status: "initialized", path: resolved_path})

      {:error, reason} ->
        send_json(conn, 400, %{error: inspect(reason)})
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  # ============================================================================
  # Command Handlers
  # ============================================================================

  defp handle_command("init", path, _params) do
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.init_project(resolved_path, []) do
      {:ok, _} -> %{status: "initialized", path: resolved_path}
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp handle_command("status", _path, _params) do
    %{
      node: node(),
      active_projects: length(Giulia.Core.ContextManager.list_projects())
    }
  end

  defp handle_command("projects", _path, _params) do
    %{projects: Giulia.Core.ContextManager.list_projects()}
  end

  defp handle_command(unknown, _path, _params) do
    %{error: "Unknown command: #{unknown}"}
  end

  defp handle_chat(message, path) do
    # Map host path to container path if running in Docker
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        # Route through the inference system
        execute_inference(message, resolved_path, context_pid)

      {:needs_init, _} ->
        %{status: "needs_init", message: "No GIULIA.md found. Run /init first."}

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp execute_inference(message, project_path, context_pid) do
    # Classify and route
    context_meta = %{file_count: Giulia.Context.Store.stats().ast_files}
    classification = Giulia.Provider.Router.route(message, context_meta)

    # Check if this is a meta command (pure Elixir, no LLM)
    if classification.provider == :elixir_native do
      handle_native_query(message)
    else
      # Use the inference pool for back-pressure
      opts = [
        project_path: project_path,
        project_pid: context_pid
      ]

      case Giulia.Inference.Pool.infer(classification.provider, message, opts) do
        {:ok, response} ->
          # Include trace for visibility
          trace = Giulia.Inference.Trace.get_last()
          %{status: "ok", response: response, trace: trace}

        {:error, :no_provider_available} ->
          %{error: "No AI provider available. Check LM Studio or API keys."}

        {:error, :timeout} ->
          %{error: "Request timed out. The model may be overloaded."}

        {:error, reason} ->
          %{error: "Inference failed: #{inspect(reason)}"}
      end
    end
  end

  defp handle_native_query(message) do
    message_lower = String.downcase(message)

    response = cond do
      String.contains?(message_lower, "module") ->
        modules = Giulia.Context.Store.list_modules()
        module_list = Enum.map_join(modules, "\n", &"- #{&1.name}")
        "Indexed modules:\n#{module_list}"

      String.contains?(message_lower, "function") ->
        # Extract module name if provided (e.g., "functions Giulia.StructuredOutput")
        module_filter = extract_module_name(message)
        functions = Giulia.Context.Store.list_functions(module_filter)

        header = if module_filter, do: "Functions in #{module_filter}:", else: "Functions (showing first 20):"
        func_list = Enum.map_join(Enum.take(functions, 50), "\n", fn f ->
          type_marker = if f.type == :defp, do: "(private)", else: ""
          "- #{f.module}.#{f.name}/#{f.arity} #{type_marker}"
        end)
        "#{header}\n#{func_list}"

      String.contains?(message_lower, "status") ->
        stats = Giulia.Context.Store.stats()
        "Index: #{stats.ast_files} files, #{stats.total_entries} entries"

      String.contains?(message_lower, "summary") ->
        Giulia.Context.Store.project_summary()

      true ->
        "I can answer questions about modules, functions, status, or summary without using the LLM."
    end

    %{status: "ok", response: response}
  end

  # Extract module name from message like "functions Giulia.StructuredOutput"
  # Matches: Giulia.Foo.Bar, Foo.Bar, FooBar (capitalized module names)
  defp extract_module_name(message) do
    case Regex.run(~r/\b([A-Z][a-zA-Z0-9]*(?:\.[A-Z][a-zA-Z0-9]*)+)\b/, message) do
      [_, module_name] -> module_name
      _ -> nil
    end
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # ============================================================================
  # SSE Streaming Helpers
  # ============================================================================

  defp stream_events(conn, request_id) do
    receive do
      {:ooda_event, %{type: :complete, response: response}} ->
        # Final event
        data = Jason.encode!(%{type: "complete", response: response})
        {:ok, conn} = chunk(conn, "event: complete\ndata: #{data}\n\n")
        Giulia.Inference.Events.unsubscribe(request_id)
        conn

      {:ooda_event, event} ->
        # Tool call or result event
        data = Jason.encode!(event)
        case chunk(conn, "event: step\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_events(conn, request_id)
          {:error, _} ->
            Giulia.Inference.Events.unsubscribe(request_id)
            conn
        end

    after
      300_000 ->
        # Timeout after 5 minutes
        Giulia.Inference.Events.unsubscribe(request_id)
        conn
    end
  end

  defp execute_inference_streaming(message, project_path, context_pid, request_id) do
    alias Giulia.Inference.Events

    context_meta = %{file_count: Giulia.Context.Store.stats().ast_files}
    classification = Giulia.Provider.Router.route(message, context_meta)

    if classification.provider == :elixir_native do
      result = handle_native_query(message)
      Events.broadcast(request_id, %{type: :complete, response: result.response})
    else
      opts = [
        project_path: project_path,
        project_pid: context_pid,
        request_id: request_id
      ]

      case Giulia.Inference.Pool.infer(classification.provider, message, opts) do
        {:ok, response} ->
          Events.broadcast(request_id, %{type: :complete, response: response})

        {:error, reason} ->
          Events.broadcast(request_id, %{type: :complete, response: "Error: #{inspect(reason)}"})
      end
    end
  end
end
