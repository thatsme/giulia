defmodule Giulia.Daemon.Endpoint do
  @moduledoc """
  HTTP API endpoint for the Giulia daemon.

  Replaces Erlang distribution with simple HTTP/JSON - works reliably
  across Docker boundaries without EPMD drama.

  All index/knowledge endpoints require a ?path= query parameter
  to scope results to a specific project.
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

  # Lightweight ping endpoint - checks project status WITHOUT triggering inference
  # Used by client at startup to check if project needs initialization
  post "/api/ping" do
    case conn.body_params do
      %{"path" => path} ->
        resolved_path = Giulia.Core.PathMapper.resolve_path(path)

        case Giulia.Core.ContextManager.get_context(resolved_path) do
          {:ok, _context_pid} ->
            send_json(conn, 200, %{status: "ok", path: resolved_path})

          {:needs_init, _} ->
            send_json(conn, 200, %{status: "needs_init", path: resolved_path})

          {:error, reason} ->
            send_json(conn, 200, %{status: "error", error: inspect(reason)})
        end

      _ ->
        send_json(conn, 400, %{error: "Missing required field: path"})
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
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        modules = Giulia.Context.Store.list_modules(project_path)
        send_json(conn, 200, %{modules: modules, count: length(modules)})
    end
  end

  # "What functions are in module X?"
  # Supports ?module=Giulia.StructuredOutput query param
  get "/api/index/functions" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module_filter = conn.query_params["module"]
        functions = Giulia.Context.Store.list_functions(project_path, module_filter)
        send_json(conn, 200, %{functions: functions, count: length(functions), module: module_filter})
    end
  end

  # Full module details — file, moduledoc, functions, types, specs, callbacks, struct
  get "/api/index/module_details" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          details = Giulia.Context.Store.module_details(project_path, module)
          send_json(conn, 200, %{module: module, details: details})
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # Project summary - The "distilled metadata" for small models
  get "/api/index/summary" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        summary = Giulia.Context.Store.project_summary(project_path)
        send_json(conn, 200, %{summary: summary})
    end
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

  # Direct search endpoint (no LLM, calls SearchCode tool directly)
  get "/api/search" do
    pattern = conn.query_params["pattern"] || conn.query_params["q"]
    path = conn.query_params["path"]

    if pattern do
      resolved_path = if path, do: Giulia.Core.PathMapper.resolve_path(path), else: File.cwd!()
      sandbox = Giulia.Core.PathSandbox.new(resolved_path)
      opts = [sandbox: sandbox]

      case Giulia.Tools.SearchCode.execute(%{"pattern" => pattern}, opts) do
        {:ok, result} -> send_json(conn, 200, %{status: "ok", results: result})
        {:error, reason} -> send_json(conn, 400, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing 'pattern' or 'q' query parameter"})
    end
  end

  # ============================================================================
  # Semantic Search Endpoints
  # ============================================================================

  # Semantic search by concept
  get "/api/search/semantic" do
    concept = conn.query_params["concept"] || conn.query_params["q"]

    if concept do
      case resolve_project_path(conn) do
        nil ->
          send_json(conn, 400, %{error: "Missing required query param: path"})

        project_path ->
          top_k =
            case Integer.parse(conn.query_params["top_k"] || "5") do
              {n, _} -> n
              :error -> 5
            end

          case Giulia.Intelligence.SemanticIndex.search(project_path, concept, top_k) do
            {:ok, %{modules: modules, functions: functions}} ->
              mod_json =
                Enum.map(modules, fn m ->
                  %{
                    module: m.id,
                    score: m.score,
                    moduledoc: m.metadata[:moduledoc] || ""
                  }
                end)

              func_json =
                Enum.map(functions, fn f ->
                  %{
                    module: f.metadata.module,
                    function: f.metadata.function,
                    arity: f.metadata.arity,
                    score: f.score,
                    file: f.metadata.file,
                    line: f.metadata.line
                  }
                end)

              send_json(conn, 200, %{
                concept: concept,
                modules: mod_json,
                functions: func_json,
                count: length(func_json)
              })

            {:error, "Semantic search unavailable" <> _} ->
              send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

            {:error, "No embeddings" <> _} ->
              send_json(conn, 404, %{error: "No embeddings for this project. Run POST /api/index/scan first."})

            {:error, reason} ->
              send_json(conn, 500, %{error: reason})
          end
      end
    else
      send_json(conn, 400, %{error: "Missing required query param: concept (or q)"})
    end
  end

  # Test Surgical Briefing (Layer 1+2 pre-processing)
  get "/api/intelligence/briefing" do
    concept = conn.query_params["prompt"] || conn.query_params["q"]

    if concept do
      case resolve_project_path(conn) do
        nil ->
          send_json(conn, 400, %{error: "Missing required query param: path"})

        project_path ->
          case Giulia.Intelligence.SurgicalBriefing.build(concept, project_path) do
            {:ok, briefing} ->
              send_json(conn, 200, %{status: "ok", briefing: briefing})

            :skip ->
              send_json(conn, 200, %{status: "skipped", briefing: nil,
                message: "Briefing skipped (unavailable, no embeddings, or below relevance threshold)"})
          end
      end
    else
      send_json(conn, 400, %{error: "Missing required query param: prompt (or q)"})
    end
  end

  # Preflight Contract Checklist (Layer 3: structured contract analysis)
  post "/api/briefing/preflight" do
    prompt = conn.body_params["prompt"]
    path = conn.body_params["path"]

    if prompt && path do
      resolved_path = Giulia.Core.PathMapper.resolve_path(path)

      top_k =
        case Integer.parse(to_string(conn.body_params["top_k"] || "5")) do
          {n, _} -> n
          :error -> 5
        end

      depth =
        case Integer.parse(to_string(conn.body_params["depth"] || "2")) do
          {n, _} -> n
          :error -> 2
        end

      case Giulia.Intelligence.Preflight.run(prompt, resolved_path, top_k: top_k, depth: depth) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required fields: prompt and path"})
    end
  end

  # Semantic search status
  get "/api/search/semantic/status" do
    case resolve_project_path(conn) do
      nil ->
        send_json(conn, 400, %{error: "Missing required query param: path"})

      project_path ->
        status = Giulia.Intelligence.SemanticIndex.status(project_path)
        send_json(conn, 200, status)
    end
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

  # ============================================================================
  # Transaction Endpoints (Transactional Exoskeleton)
  # ============================================================================

  # Toggle transaction mode preference for the project
  post "/api/transaction/enable" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        new_mode = Giulia.Core.ProjectContext.toggle_transaction_preference(context_pid)
        status = if new_mode, do: "enabled", else: "disabled"
        send_json(conn, 200, %{status: status, transaction_mode: new_mode})

      _ ->
        send_json(conn, 400, %{error: "No active project context"})
    end
  end

  # View transaction preference (staged files are per-inference, ephemeral)
  get "/api/transaction/staged" do
    path = conn.query_params["path"]
    resolved_path = if path, do: Giulia.Core.PathMapper.resolve_path(path), else: nil

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        pref = Giulia.Core.ProjectContext.transaction_preference(context_pid)
        send_json(conn, 200, %{
          transaction_mode: pref,
          staged_files: [],
          count: 0,
          note: "Staged files exist only during active inference sessions"
        })

      _ ->
        send_json(conn, 200, %{transaction_mode: false, staged_files: [], count: 0})
    end
  end

  # Reset transaction preference
  post "/api/transaction/rollback" do
    path = conn.body_params["path"]
    resolved_path = Giulia.Core.PathMapper.resolve_path(path)

    case Giulia.Core.ContextManager.get_context(resolved_path) do
      {:ok, context_pid} ->
        # If preference is on, toggle it off
        pref = Giulia.Core.ProjectContext.transaction_preference(context_pid)
        if pref, do: Giulia.Core.ProjectContext.toggle_transaction_preference(context_pid)
        send_json(conn, 200, %{status: "reset", transaction_mode: false})

      _ ->
        send_json(conn, 400, %{error: "No active project context"})
    end
  end

  # ============================================================================
  # Knowledge Graph Endpoints (Project Topology)
  # ============================================================================

  # Graph statistics: vertices, edges, components, hubs
  get "/api/knowledge/stats" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        stats = Giulia.Knowledge.Store.stats(project_path)
        # Convert hub tuples {name, degree} to maps for JSON encoding
        hubs = Enum.map(stats.hubs || [], fn {name, degree} -> %{module: name, degree: degree} end)
        send_json(conn, 200, %{stats | hubs: hubs})
    end
  end

  # Who depends on module X (incoming edges = dependents)
  get "/api/knowledge/dependents" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.dependents(project_path, module) do
            {:ok, deps} ->
              send_json(conn, 200, %{module: module, dependents: deps, count: length(deps)})

            {:error, {:not_found, _}} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # What module X depends on (outgoing edges = dependencies)
  get "/api/knowledge/dependencies" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.dependencies(project_path, module) do
            {:ok, deps} ->
              send_json(conn, 200, %{module: module, dependencies: deps, count: length(deps)})

            {:error, {:not_found, _}} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # Centrality score (hub detection): in-degree, out-degree, dependents list
  get "/api/knowledge/centrality" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]

        if module do
          case Giulia.Knowledge.Store.centrality(project_path, module) do
            {:ok, result} ->
              send_json(conn, 200, Map.put(result, :module, module))

            {:error, :not_found} ->
              send_json(conn, 404, %{error: "Module not found in graph", module: module})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # Impact map: upstream + downstream dependencies at given depth
  get "/api/knowledge/impact" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        module = conn.query_params["module"]
        depth = case Integer.parse(conn.query_params["depth"] || "2") do
          {n, _} -> n
          :error -> 2
        end

        if module do
          case Giulia.Knowledge.Store.impact_map(project_path, module, depth) do
            {:ok, result} ->
              # Convert tuples {vertex, depth} to maps for JSON encoding
              upstream = Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end)
              downstream = Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end)
              # Convert function_edges tuples {name, targets} to maps
              func_edges = Enum.map(result.function_edges, fn {name, targets} ->
                %{function: name, calls: targets}
              end)
              send_json(conn, 200, %{result | upstream: upstream, downstream: downstream, function_edges: func_edges})

            {:error, {:not_found, _, suggestions, graph_info}} ->
              send_json(conn, 404, %{
                error: "Module not found in graph",
                module: module,
                suggestions: suggestions,
                graph_info: graph_info
              })
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: module"})
        end
    end
  end

  # Behaviour-implementer integrity check
  get "/api/knowledge/integrity" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.check_all_behaviours(project_path) do
          {:ok, :consistent} ->
            send_json(conn, 200, %{status: "consistent", fractures: []})

          {:error, fractures} when is_map(fractures) ->
            formatted =
              Enum.map(fractures, fn {behaviour, impl_fractures} ->
                %{
                  behaviour: behaviour,
                  fractures: Enum.map(impl_fractures, fn %{implementer: impl, missing: missing} ->
                    %{
                      implementer: impl,
                      missing: Enum.map(missing, fn {name, arity} -> "#{name}/#{arity}" end)
                    }
                  end)
                }
              end)

            send_json(conn, 200, %{status: "fractured", fractures: formatted})
        end
    end
  end

  # Dead code detection — functions defined but never called
  get "/api/knowledge/dead_code" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_dead_code(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Circular dependency detection — strongly connected components
  get "/api/knowledge/cycles" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_cycles(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # God module detection — high complexity + centrality + function count
  get "/api/knowledge/god_modules" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_god_modules(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Orphan spec detection — @spec without matching function definition
  get "/api/knowledge/orphan_specs" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_orphan_specs(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Fan-in/fan-out analysis — dependency direction imbalance
  get "/api/knowledge/fan_in_out" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_fan_in_out(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Coupling score — function-level dependency strength between module pairs
  get "/api/knowledge/coupling" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_coupling(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # API surface analysis — public vs private function ratio per module
  get "/api/knowledge/api_surface" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.find_api_surface(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Change risk score — composite refactoring priority
  get "/api/knowledge/change_risk" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.change_risk_score(project_path) do
          {:ok, result} -> send_json(conn, 200, result)
        end
    end
  end

  # Shortest path between two modules
  get "/api/knowledge/path" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        from = conn.query_params["from"]
        to = conn.query_params["to"]

        if from && to do
          case Giulia.Knowledge.Store.trace_path(project_path, from, to) do
            {:ok, :no_path} ->
              send_json(conn, 200, %{from: from, to: to, path: nil, message: "No path found"})

            {:ok, path} ->
              send_json(conn, 200, %{from: from, to: to, path: path, hops: length(path) - 1})

            {:error, {:not_found, vertex}} ->
              send_json(conn, 404, %{error: "Vertex not found in graph", vertex: vertex})
          end
        else
          send_json(conn, 400, %{error: "Missing required query params: from, to"})
        end
    end
  end

  # ============================================================================
  # Synthesized Logic View (Oracle Endpoints)
  # ============================================================================

  # Logic flow: function-level Dijkstra path between two MFA vertices
  get "/api/knowledge/logic_flow" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        from = conn.query_params["from"]
        to = conn.query_params["to"]

        if from && to do
          case Giulia.Knowledge.Store.logic_flow(project_path, from, to) do
            {:ok, :no_path} ->
              send_json(conn, 200, %{from: from, to: to, steps: nil, hop_count: 0, message: "No path found"})

            {:ok, steps} ->
              send_json(conn, 200, %{from: from, to: to, steps: steps, hop_count: max(length(steps) - 1, 0)})

            {:error, {:not_found, vertex}} ->
              send_json(conn, 404, %{error: "MFA vertex not found in graph", vertex: vertex})
          end
        else
          send_json(conn, 400, %{error: "Missing required query params: from, to (MFA format: Module.func/arity)"})
        end
    end
  end

  # Style oracle: semantic search + quality gate (@spec + @doc)
  get "/api/knowledge/style_oracle" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        query = conn.query_params["q"]

        if query do
          top_k =
            case Integer.parse(conn.query_params["top_k"] || "3") do
              {n, _} -> n
              :error -> 3
            end

          case Giulia.Knowledge.Store.style_oracle(project_path, query, top_k) do
            {:ok, result} ->
              send_json(conn, 200, result)

            {:error, "Semantic search unavailable" <> _} ->
              send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

            {:error, reason} ->
              send_json(conn, 500, %{error: inspect(reason)})
          end
        else
          send_json(conn, 400, %{error: "Missing required query param: q"})
        end
    end
  end

  # Pre-impact check: rename/remove risk analysis
  post "/api/knowledge/pre_impact_check" do
    path = conn.body_params["path"]
    module = conn.body_params["module"]
    action = conn.body_params["action"]

    if path && module && action do
      resolved_path = Giulia.Core.PathMapper.resolve_path(path)

      case Giulia.Knowledge.Store.pre_impact_check(resolved_path, conn.body_params) do
        {:ok, result} ->
          send_json(conn, 200, result)

        {:error, {:not_found, vertex}} ->
          send_json(conn, 404, %{error: "Vertex not found in graph", vertex: vertex})

        {:error, {:unknown_action, act}} ->
          send_json(conn, 400, %{error: "Unknown action: #{act}. Use: rename_function, remove_function, rename_module"})

        {:error, {:invalid_target, target}} ->
          send_json(conn, 400, %{error: "Invalid target format: #{target}. Use: func_name/arity"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "Missing required fields: path, module, action"})
    end
  end

  # Heatmap: composite module health scores
  get "/api/knowledge/heatmap" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        case Giulia.Knowledge.Store.heatmap(project_path) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # ============================================================================
  # Principal Consultant Endpoints (Build 89)
  # ============================================================================

  # Unprotected hubs: hub modules with low spec/doc coverage
  get "/api/knowledge/unprotected_hubs" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        hub_threshold =
          case Integer.parse(conn.query_params["hub_threshold"] || "3") do
            {n, _} -> n
            :error -> 3
          end

        spec_threshold =
          case Float.parse(conn.query_params["spec_threshold"] || "0.5") do
            {f, _} -> f
            :error -> 0.5
          end

        case Giulia.Knowledge.Store.find_unprotected_hubs(project_path,
               hub_threshold: hub_threshold, spec_threshold: spec_threshold) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # Struct lifecycle: data flow tracing across modules
  get "/api/knowledge/struct_lifecycle" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        struct_filter = conn.query_params["struct"]

        case Giulia.Knowledge.Store.struct_lifecycle(project_path, struct_filter) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # Semantic duplicates: find redundant logic via embedding similarity
  get "/api/knowledge/duplicates" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        threshold =
          case Float.parse(conn.query_params["threshold"] || "0.85") do
            {f, _} -> f
            :error -> 0.85
          end

        max_clusters =
          case Integer.parse(conn.query_params["max"] || "20") do
            {n, _} -> n
            :error -> 20
          end

        case Giulia.Intelligence.SemanticIndex.find_duplicates(project_path,
               threshold: threshold, max: max_clusters) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, "Semantic search unavailable" <> _} ->
            send_json(conn, 503, %{error: "Semantic search unavailable. EmbeddingServing not loaded."})

          {:error, reason} ->
            send_json(conn, 500, %{error: reason})
        end
    end
  end

  # Unified audit: combines all 4 Principal Consultant features
  get "/api/knowledge/audit" do
    case resolve_project_path(conn) do
      nil -> send_json(conn, 400, %{error: "Missing required query param: path"})
      project_path ->
        # Run all 4 analyses
        unprotected_hubs =
          case Giulia.Knowledge.Store.find_unprotected_hubs(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{modules: [], count: 0, severity_counts: %{red: 0, yellow: 0}}
          end

        struct_lifecycle =
          case Giulia.Knowledge.Store.struct_lifecycle(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{structs: [], count: 0}
          end

        semantic_duplicates =
          case Giulia.Intelligence.SemanticIndex.find_duplicates(project_path) do
            {:ok, result} -> result
            {:error, _} -> %{clusters: [], count: 0, note: "Semantic search unavailable"}
          end

        behaviour_integrity =
          case Giulia.Knowledge.Store.check_all_behaviours(project_path) do
            {:ok, :consistent} ->
              %{status: "consistent", fractures: []}

            {:error, fractures} when is_map(fractures) ->
              formatted =
                Enum.map(fractures, fn {behaviour, impl_fractures} ->
                  %{
                    behaviour: behaviour,
                    fractures: Enum.map(impl_fractures, fn frac ->
                      missing = Map.get(frac, :missing, [])
                      injected = Map.get(frac, :injected, [])
                      %{
                        implementer: frac.implementer,
                        missing: Enum.map(missing, fn {name, arity} -> "#{name}/#{arity}" end),
                        injected: Enum.map(injected, fn {name, arity} -> "#{name}/#{arity}" end)
                      }
                    end)
                  }
                end)

              %{status: "fractured", fractures: formatted}

            _ ->
              %{status: "unknown", fractures: []}
          end

        send_json(conn, 200, %{
          audit_version: "build_89",
          unprotected_hubs: unprotected_hubs,
          struct_lifecycle: struct_lifecycle,
          semantic_duplicates: semantic_duplicates,
          behaviour_integrity: behaviour_integrity
        })
    end
  end

  # ============================================================================
  # Approval Endpoints (Interactive Consent Gate)
  # ============================================================================

  # Respond to an approval request
  post "/api/approval/:approval_id" do
    approval_id = conn.path_params["approval_id"]
    approved = conn.body_params["approved"] == true

    Giulia.Inference.Approval.respond(approval_id, approved)
    send_json(conn, 200, %{status: "ok", approval_id: approval_id, approved: approved})
  end

  # Get pending approval request info
  get "/api/approval/:approval_id" do
    approval_id = conn.path_params["approval_id"]

    case Giulia.Inference.Approval.get_pending(approval_id) do
      {:ok, info} ->
        send_json(conn, 200, info)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "Approval request not found or already resolved"})
    end
  end

  # List all pending approval requests
  get "/api/approvals" do
    pending = Giulia.Inference.Approval.list_pending()
    send_json(conn, 200, %{pending: pending, count: length(pending)})
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
    context_meta = %{file_count: Giulia.Context.Store.stats(project_path).ast_files}
    classification = Giulia.Provider.Router.route(message, context_meta)

    # Check if this is a meta command (pure Elixir, no LLM)
    if classification.provider == :elixir_native do
      handle_native_query(message, project_path)
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

  defp handle_native_query(message, project_path) do
    message_lower = String.downcase(message)

    response = cond do
      String.contains?(message_lower, "module") ->
        modules = Giulia.Context.Store.list_modules(project_path)
        module_list = Enum.map_join(modules, "\n", &"- #{&1.name}")
        "Indexed modules:\n#{module_list}"

      String.contains?(message_lower, "function") ->
        # Extract module name if provided (e.g., "functions Giulia.StructuredOutput")
        module_filter = extract_module_name(message)
        functions = Giulia.Context.Store.list_functions(project_path, module_filter)

        header = if module_filter, do: "Functions in #{module_filter}:", else: "Functions (showing first 20):"
        func_list = Enum.map_join(Enum.take(functions, 50), "\n", fn f ->
          type_marker = if f.type == :defp, do: "(private)", else: ""
          "- #{f.module}.#{f.name}/#{f.arity} #{type_marker}"
        end)
        "#{header}\n#{func_list}"

      String.contains?(message_lower, "status") ->
        stats = Giulia.Context.Store.stats(project_path)
        "Index: #{stats.ast_files} files, #{stats.total_entries} entries"

      String.contains?(message_lower, "summary") ->
        Giulia.Context.Store.project_summary(project_path)

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

  # Resolve project path from ?path= query param
  defp resolve_project_path(conn) do
    case conn.query_params["path"] do
      nil -> nil
      path -> Giulia.Core.PathMapper.resolve_path(path)
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

    context_meta = %{file_count: Giulia.Context.Store.stats(project_path).ast_files}
    classification = Giulia.Provider.Router.route(message, context_meta)

    if classification.provider == :elixir_native do
      result = handle_native_query(message, project_path)
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
