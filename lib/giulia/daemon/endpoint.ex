defmodule Giulia.Daemon.Endpoint do
  @moduledoc """
  HTTP API endpoint for the Giulia daemon.

  Replaces Erlang distribution with simple HTTP/JSON - works reliably
  across Docker boundaries without EPMD drama.
  """

  use Plug.Router

  plug Plug.Logger
  plug :match
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
  get "/api/index/functions" do
    functions = Giulia.Context.Store.list_functions()
    send_json(conn, 200, %{functions: functions, count: length(functions)})
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
          %{status: "ok", response: response}

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
        functions = Giulia.Context.Store.list_functions()
        func_list = Enum.map_join(Enum.take(functions, 20), "\n", &"- #{&1.module}.#{&1.name}/#{&1.arity}")
        "Functions (showing first 20):\n#{func_list}"

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

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
