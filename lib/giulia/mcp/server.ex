defmodule Giulia.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server exposing Giulia code intelligence as
  tools and resources.

  Uses the Streamable HTTP transport via anubis_mcp. Clients connect to
  the /mcp endpoint, authenticate with a Bearer token, and can discover
  and invoke Giulia analysis tools through the standard MCP protocol.

  Tool dispatch calls the same underlying business logic as the REST API —
  no HTTP self-requests. Each tool name maps directly to a function in
  Knowledge.Store, Context.Store, Runtime.Inspector, etc.
  """

  use Anubis.Server,
    name: "giulia",
    version: Giulia.MixProject.project()[:version] || "0.0.0",
    capabilities: [:tools, :resources]

  require Logger

  alias Giulia.MCP.{ResourceProvider, ToolSchema}
  alias Anubis.MCP.Error
  alias Anubis.Server.Response

  @tool_timeout 30_000

  @impl true
  def init(client_info, frame) do
    Logger.info("[MCP] Client connected: #{inspect(client_info["name"])}")

    frame =
      frame
      |> register_all_tools()
      |> ResourceProvider.register_templates()

    {:ok, frame}
  end

  # ============================================================================
  # Tool Dispatch — grouped by category prefix
  # ============================================================================

  @impl true
  def handle_tool_call("knowledge_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_knowledge(sub, args) end)
  end

  def handle_tool_call("index_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_index(sub, args) end)
  end

  def handle_tool_call("search_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_search(sub, args) end)
  end

  def handle_tool_call("runtime_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_runtime(sub, args) end)
  end

  def handle_tool_call("intelligence_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_intelligence(sub, args) end)
  end

  def handle_tool_call("briefing_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_intelligence("briefing_" <> sub, args) end)
  end

  def handle_tool_call("brief_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_intelligence("brief_" <> sub, args) end)
  end

  def handle_tool_call("plan_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_intelligence("plan_" <> sub, args) end)
  end

  def handle_tool_call("transaction_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_transaction(sub, args) end)
  end

  def handle_tool_call("approval_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_approval(sub, args) end)
  end

  def handle_tool_call("monitor_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_monitor(sub, args) end)
  end

  def handle_tool_call("discovery_" <> sub, args, frame) do
    execute(frame, fn -> dispatch_discovery(sub, args) end)
  end

  def handle_tool_call(name, _args, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "Unknown tool: #{name}"}), frame}
  end

  # ============================================================================
  # Resources
  # ============================================================================

  @impl true
  def handle_resource_read(uri, frame) do
    ResourceProvider.read(uri, frame)
  end

  @impl true
  def handle_info(_msg, frame) do
    {:noreply, frame}
  end

  # ============================================================================
  # Knowledge Dispatch (25 tools)
  # ============================================================================

  defp dispatch_knowledge("stats", args) do
    with {:ok, path} <- require_path(args) do
      stats = Giulia.Knowledge.Store.stats(path)
      hubs = Enum.map(stats.hubs || [], fn {name, degree} -> %{module: name, degree: degree} end)
      {:ok, %{stats | hubs: hubs}}
    end
  end

  defp dispatch_knowledge("dependents", args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Giulia.Knowledge.Store.dependents(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependents: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  defp dispatch_knowledge("dependencies", args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Giulia.Knowledge.Store.dependencies(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependencies: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  defp dispatch_knowledge("centrality", args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Giulia.Knowledge.Store.centrality(path, module) do
        {:ok, result} -> {:ok, Map.put(result, :module, module)}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  defp dispatch_knowledge("impact", args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      depth = parse_int(args["depth"], 2)

      case Giulia.Knowledge.Store.impact_map(path, module, depth) do
        {:ok, result} ->
          upstream = Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end)
          downstream = Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end)

          func_edges =
            Enum.map(result.function_edges, fn {name, targets} ->
              %{function: name, calls: targets}
            end)

          {:ok, %{result | upstream: upstream, downstream: downstream, function_edges: func_edges}}

        {:error, {:not_found, _, suggestions, graph_info}} ->
          {:error, "Module not found in graph: #{module}. Suggestions: #{inspect(suggestions)}. Graph: #{inspect(graph_info)}"}
      end
    end
  end

  defp dispatch_knowledge("integrity", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Knowledge.Store.check_all_behaviours(path) do
        {:ok, :consistent} ->
          {:ok, %{status: "consistent", fractures: []}}

        {:error, fractures} when is_map(fractures) ->
          formatted =
            Enum.map(fractures, fn {behaviour, impl_fractures} ->
              %{behaviour: behaviour, fractures: Enum.map(impl_fractures, &format_fracture/1)}
            end)

          {:ok, %{status: "fractured", fractures: formatted}}
      end
    end
  end

  defp dispatch_knowledge("dead_code", args), do: simple_knowledge_call(args, :find_dead_code)
  defp dispatch_knowledge("cycles", args), do: simple_knowledge_call(args, :find_cycles)
  defp dispatch_knowledge("god_modules", args), do: simple_knowledge_call(args, :find_god_modules)
  defp dispatch_knowledge("orphan_specs", args), do: simple_knowledge_call(args, :find_orphan_specs)
  defp dispatch_knowledge("fan_in_out", args), do: simple_knowledge_call(args, :find_fan_in_out)
  defp dispatch_knowledge("coupling", args), do: simple_knowledge_call(args, :find_coupling)
  defp dispatch_knowledge("api_surface", args), do: simple_knowledge_call(args, :find_api_surface)
  defp dispatch_knowledge("change_risk", args), do: simple_knowledge_call(args, :change_risk_score)

  defp dispatch_knowledge("path", args) do
    with {:ok, path} <- require_path(args),
         {:ok, from} <- require_param(args, "from"),
         {:ok, to} <- require_param(args, "to") do
      case Giulia.Knowledge.Store.trace_path(path, from, to) do
        {:ok, :no_path} -> {:ok, %{from: from, to: to, path: nil, message: "No path found"}}
        {:ok, trace} -> {:ok, %{from: from, to: to, path: trace, hops: length(trace) - 1}}
        {:error, {:not_found, vertex}} -> {:error, "Vertex not found in graph: #{vertex}"}
      end
    end
  end

  defp dispatch_knowledge("logic_flow", args) do
    with {:ok, path} <- require_path(args),
         {:ok, from} <- require_param(args, "from"),
         {:ok, to} <- require_param(args, "to") do
      case Giulia.Knowledge.Store.logic_flow(path, from, to) do
        {:ok, :no_path} -> {:ok, %{from: from, to: to, steps: nil, hop_count: 0, message: "No path found"}}
        {:ok, steps} -> {:ok, %{from: from, to: to, steps: steps, hop_count: max(length(steps) - 1, 0)}}
        {:error, {:not_found, vertex}} -> {:error, "MFA vertex not found in graph: #{vertex}"}
      end
    end
  end

  defp dispatch_knowledge("style_oracle", args) do
    with {:ok, path} <- require_path(args),
         {:ok, q} <- require_param(args, "q") do
      top_k = parse_int(args["top_k"], 3)

      case Giulia.Knowledge.Store.style_oracle(path, q, top_k) do
        {:ok, result} -> {:ok, result}
        {:error, "Semantic search unavailable" <> _} -> {:error, "Semantic search unavailable. EmbeddingServing not loaded."}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_knowledge("pre_impact_check", args) do
    with {:ok, path} <- require_path(args),
         {:ok, _module} <- require_param(args, "module"),
         {:ok, _action} <- require_param(args, "action") do
      case Giulia.Knowledge.Store.pre_impact_check(path, args) do
        {:ok, result} -> {:ok, result}
        {:error, {:not_found, vertex}} -> {:error, "Vertex not found in graph: #{vertex}"}
        {:error, {:unknown_action, act}} -> {:error, "Unknown action: #{act}. Use: rename_function, remove_function, rename_module"}
        {:error, {:invalid_target, target}} -> {:error, "Invalid target format: #{target}. Use: func_name/arity"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_knowledge("heatmap", args), do: simple_knowledge_call(args, :heatmap)

  defp dispatch_knowledge("unprotected_hubs", args) do
    with {:ok, path} <- require_path(args) do
      hub_threshold = parse_int(args["hub_threshold"], 3)
      spec_threshold = parse_float(args["spec_threshold"], 0.5)

      case Giulia.Knowledge.Store.find_unprotected_hubs(path,
             hub_threshold: hub_threshold, spec_threshold: spec_threshold) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_knowledge("struct_lifecycle", args) do
    with {:ok, path} <- require_path(args) do
      struct_filter = args["struct"]

      case Giulia.Knowledge.Store.struct_lifecycle(path, struct_filter) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_knowledge("duplicates", args) do
    with {:ok, path} <- require_path(args) do
      threshold = parse_float(args["threshold"], 0.85)
      max_clusters = parse_int(args["max"], 20)

      case Giulia.Intelligence.SemanticIndex.find_duplicates(path,
             threshold: threshold, max: max_clusters) do
        {:ok, result} -> {:ok, result}
        {:error, "Semantic search unavailable" <> _} -> {:error, "Semantic search unavailable. EmbeddingServing not loaded."}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_knowledge("audit", args) do
    with {:ok, path} <- require_path(args) do
      unprotected_hubs =
        case Giulia.Knowledge.Store.find_unprotected_hubs(path) do
          {:ok, result} -> result
          {:error, _} -> %{modules: [], count: 0, severity_counts: %{red: 0, yellow: 0}}
        end

      struct_lifecycle =
        case Giulia.Knowledge.Store.struct_lifecycle(path) do
          {:ok, result} -> result
          {:error, _} -> %{structs: [], count: 0}
        end

      semantic_duplicates =
        case Giulia.Intelligence.SemanticIndex.find_duplicates(path) do
          {:ok, result} -> result
          {:error, _} -> %{clusters: [], count: 0, note: "Semantic search unavailable"}
        end

      behaviour_integrity =
        case Giulia.Knowledge.Store.check_all_behaviours(path) do
          {:ok, :consistent} ->
            %{status: "consistent", fractures: []}

          {:error, fractures} when is_map(fractures) ->
            formatted =
              Enum.map(fractures, fn {behaviour, impl_fractures} ->
                %{behaviour: behaviour, fractures: Enum.map(impl_fractures, &format_fracture/1)}
              end)

            %{status: "fractured", fractures: formatted}

          _ ->
            %{status: "unknown", fractures: []}
        end

      {:ok, %{
        audit_version: "build_90",
        unprotected_hubs: unprotected_hubs,
        struct_lifecycle: struct_lifecycle,
        semantic_duplicates: semantic_duplicates,
        behaviour_integrity: behaviour_integrity
      }}
    end
  end

  defp dispatch_knowledge("topology", args) do
    with {:ok, path} <- require_path(args) do
      {:ok, edges} = Giulia.Knowledge.Store.all_dependencies(path)
      {:ok, heatmap} = Giulia.Knowledge.Store.heatmap(path)
      heatmap_map = Map.new(heatmap.modules, fn m -> {m.module, m} end)

      {:ok, fan_data} = Giulia.Knowledge.Store.find_fan_in_out(path)
      fan_map = Map.new(fan_data.modules, fn m -> {m.module, m} end)

      all_modules =
        Enum.uniq(
          Enum.map(heatmap.modules, & &1.module) ++
            Enum.flat_map(edges, fn {s, t, _} -> [s, t] end)
        )

      nodes =
        Enum.map(all_modules, fn mod ->
          h = Map.get(heatmap_map, mod, %{})
          f = Map.get(fan_map, mod, %{})
          breakdown = Map.get(h, :breakdown, %{})

          %{
            data: %{
              id: mod,
              label: mod |> String.split(".") |> Enum.slice(-2..-1) |> Enum.join("."),
              score: Map.get(h, :score, 0),
              zone: Map.get(h, :zone, "green"),
              fan_in: Map.get(f, :fan_in, 0),
              fan_out: Map.get(f, :fan_out, 0),
              complexity: Map.get(breakdown, :complexity, 0),
              has_test: Map.get(breakdown, :has_test, false)
            }
          }
        end)

      cy_edges =
        Enum.map(edges, fn {source, target, label} ->
          %{data: %{source: source, target: target, label: to_string(label)}}
        end)

      {:ok, %{nodes: nodes, edges: cy_edges, node_count: length(nodes), edge_count: length(cy_edges)}}
    end
  end

  defp dispatch_knowledge("conventions", args) do
    with {:ok, path} <- require_path(args) do
      suppress = parse_suppress(args["suppress"])
      opts = [suppress: suppress]
      opts = if args["module"], do: Keyword.put(opts, :module, args["module"]), else: opts

      case Giulia.Knowledge.Store.find_conventions(path, opts) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, "conventions failed: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch_knowledge(sub, _args), do: {:error, "Unknown knowledge tool: #{sub}"}

  # ============================================================================
  # Index Dispatch (9 tools)
  # ============================================================================

  defp dispatch_index("modules", args) do
    with {:ok, path} <- require_path(args) do
      modules = Giulia.Context.Store.Query.list_modules(path)
      {:ok, %{modules: modules, count: length(modules)}}
    end
  end

  defp dispatch_index("functions", args) do
    with {:ok, path} <- require_path(args) do
      module_filter = args["module"]
      functions = Giulia.Context.Store.Query.list_functions(path, module_filter)
      {:ok, %{functions: functions, count: length(functions), module: module_filter}}
    end
  end

  defp dispatch_index("module_details", args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      details = Giulia.Context.Store.Formatter.module_details(path, module)
      {:ok, %{module: module, details: details}}
    end
  end

  defp dispatch_index("summary", args) do
    with {:ok, path} <- require_path(args) do
      summary = Giulia.Context.Store.Formatter.project_summary(path)
      {:ok, %{summary: summary}}
    end
  end

  defp dispatch_index("status", args) do
    status =
      case args["path"] do
        nil -> Giulia.Context.Indexer.status()
        path ->
          resolved = Giulia.Core.PathMapper.resolve_path(path)
          Giulia.Context.Indexer.status(resolved)
      end

    cache_status =
      case status.project_path do
        nil ->
          %{cache_status: "no_project"}

        project_path ->
          merkle_root =
            case Giulia.Persistence.Loader.cached_merkle_root(project_path) do
              {:ok, hash} -> String.slice(Base.encode16(hash, case: :lower), 0, 12)
              :not_cached -> nil
            end

          %{cache_status: if(merkle_root, do: "warm", else: "cold"), merkle_root: merkle_root}
      end

    {:ok, Map.merge(status, cache_status)}
  end

  defp dispatch_index("scan", args) do
    with {:ok, path} <- require_path(args) do
      Giulia.Context.Indexer.scan(path)
      {:ok, %{status: "scanning", path: path}}
    end
  end

  defp dispatch_index("verify", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Persistence.Store.get_db(path) do
        {:ok, db} ->
          case CubDB.get(db, {:merkle, :tree}) do
            nil ->
              {:ok, %{status: "no_cache", verified: false}}

            tree ->
              case Giulia.Persistence.Merkle.verify(tree) do
                :ok ->
                  {:ok, %{
                    status: "ok",
                    verified: true,
                    root: String.slice(Base.encode16(Giulia.Persistence.Merkle.root_hash(tree), case: :lower), 0, 12),
                    leaf_count: tree.leaf_count
                  }}

                {:error, :corrupted} ->
                  {:ok, %{status: "corrupted", verified: false, leaf_count: tree.leaf_count}}
              end
          end

        {:error, _} ->
          {:ok, %{status: "no_cache", verified: false}}
      end
    end
  end

  defp dispatch_index("compact", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Persistence.Store.compact(path) do
        :ok -> {:ok, %{status: "compacting", path: path}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_index("complexity", args) do
    with {:ok, path} <- require_path(args) do
      module_filter = args["module"]
      min_complexity = parse_int(args["min"], 0)
      result_limit = parse_int(args["limit"], 50)

      functions =
        Giulia.Context.Store.Query.list_functions(path, module_filter)
        |> Enum.filter(fn f -> f.complexity >= min_complexity end)
        |> Enum.sort_by(& &1.complexity, :desc)
        |> Enum.take(result_limit)

      {:ok, %{functions: functions, count: length(functions), module: module_filter, min_complexity: min_complexity}}
    end
  end

  defp dispatch_index(sub, _args), do: {:error, "Unknown index tool: #{sub}"}

  # ============================================================================
  # Search Dispatch (3 tools)
  # ============================================================================

  defp dispatch_search("text", args) do
    with {:ok, pattern} <- require_param(args, "pattern") do
      path = args["path"]
      resolved = if path, do: Giulia.Core.PathMapper.resolve_path(path), else: nil
      sandbox = if resolved, do: Giulia.Core.PathSandbox.new(resolved), else: nil
      result = Giulia.Tools.SearchCode.execute(pattern, sandbox)
      {:ok, result}
    end
  end

  defp dispatch_search("semantic", args) do
    with {:ok, path} <- require_path(args),
         {:ok, concept} <- require_param(args, "concept") do
      top_k = parse_int(args["top_k"], 5)

      case Giulia.Intelligence.SemanticIndex.search(path, concept, top_k) do
        {:ok, results} -> {:ok, %{results: results, count: length(results), concept: concept}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_search("semantic_status", args) do
    with {:ok, path} <- require_path(args) do
      status = Giulia.Intelligence.SemanticIndex.status(path)
      {:ok, status}
    end
  end

  defp dispatch_search(sub, _args), do: {:error, "Unknown search tool: #{sub}"}

  # ============================================================================
  # Runtime Dispatch (16 tools)
  # ============================================================================

  defp dispatch_runtime("pulse", args) do
    node_ref = resolve_node(args["node"])
    result = Giulia.Runtime.Inspector.pulse(node_ref)
    {:ok, result}
  end

  defp dispatch_runtime("top_processes", args) do
    node_ref = resolve_node(args["node"])

    metric =
      try do
        if args["metric"], do: String.to_existing_atom(args["metric"]), else: :reductions
      rescue
        ArgumentError -> :reductions
      end

    result = Giulia.Runtime.Inspector.top_processes(node_ref, metric)
    {:ok, result}
  end

  defp dispatch_runtime("hot_spots", args) do
    node_ref = resolve_node(args["node"])
    path = if args["path"], do: Giulia.Core.PathMapper.resolve_path(args["path"]), else: nil
    result = Giulia.Runtime.Inspector.hot_spots(node_ref, path)
    {:ok, result}
  end

  defp dispatch_runtime("trace", args) do
    with {:ok, module} <- require_param(args, "module") do
      node_ref = resolve_node(args["node"])
      duration = parse_int(args["duration"], 5000)
      result = Giulia.Runtime.Inspector.trace(node_ref, module, duration)
      {:ok, result}
    end
  end

  defp dispatch_runtime("history", args) do
    node_ref = resolve_node(args["node"])
    last_n = parse_int(args["last"], 20)
    result = Giulia.Runtime.Collector.history(node_ref, last_n)
    {:ok, result}
  end

  defp dispatch_runtime("trend", args) do
    node_ref = resolve_node(args["node"])

    metric =
      try do
        if args["metric"], do: String.to_existing_atom(args["metric"]), else: :memory
      rescue
        ArgumentError -> :memory
      end

    result = Giulia.Runtime.Collector.trend(node_ref, metric)
    {:ok, result}
  end

  defp dispatch_runtime("alerts", args) do
    node_ref = resolve_node(args["node"])
    result = Giulia.Runtime.Collector.alerts(node_ref)
    {:ok, result}
  end

  defp dispatch_runtime("connect", args) do
    with {:ok, node_str} <- require_param(args, "node") do
      case Giulia.Daemon.Helpers.safe_to_node_atom(node_str) do
        {:ok, node_atom} ->
          cookie = args["cookie"]
          result = Giulia.Runtime.Inspector.connect(node_atom, cookie)
          {:ok, result}

        {:error, reason} ->
          {:error, "Invalid node name: #{reason}"}
      end
    end
  end

  defp dispatch_runtime("monitor_status", _args) do
    result = Giulia.Runtime.Monitor.status()
    {:ok, result}
  end

  defp dispatch_runtime("profiles", args) do
    limit = parse_int(args["limit"], 20)
    result = Giulia.Runtime.Monitor.list_profiles(limit)
    {:ok, result}
  end

  defp dispatch_runtime("profile_latest", _args) do
    case Giulia.Runtime.Monitor.latest_profile() do
      {:ok, profile} -> {:ok, profile}
      {:error, :no_profiles} -> {:error, "No profiles available"}
    end
  end

  defp dispatch_runtime("profile_by_id", args) do
    with {:ok, id} <- require_param(args, "id") do
      case Giulia.Runtime.Monitor.get_profile(id) do
        {:ok, profile} -> {:ok, profile}
        {:error, :not_found} -> {:error, "Profile not found: #{id}"}
      end
    end
  end

  defp dispatch_runtime("ingest", args) do
    result = Giulia.Runtime.IngestStore.ingest(args)
    {:ok, result}
  end

  defp dispatch_runtime("ingest_finalize", args) do
    result = Giulia.Runtime.IngestStore.finalize(args)
    {:ok, result}
  end

  defp dispatch_runtime("observations", _args) do
    result = Giulia.Runtime.IngestStore.list_observations()
    {:ok, result}
  end

  defp dispatch_runtime("observation_by_session_id", args) do
    with {:ok, session_id} <- require_param(args, "session_id") do
      case Giulia.Runtime.IngestStore.get_observation(session_id) do
        {:ok, obs} -> {:ok, obs}
        {:error, :not_found} -> {:error, "Observation not found: #{session_id}"}
      end
    end
  end

  defp dispatch_runtime(sub, _args), do: {:error, "Unknown runtime tool: #{sub}"}

  # ============================================================================
  # Intelligence Dispatch (5 tools)
  # ============================================================================

  defp dispatch_intelligence("briefing", args) do
    with {:ok, path} <- require_path(args) do
      concept = args["prompt"] || args["q"]

      if concept do
        case Giulia.Intelligence.SurgicalBriefing.build(path, concept) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, inspect(reason)}
        end
      else
        {:error, "Missing required parameter: prompt (or q)"}
      end
    end
  end

  defp dispatch_intelligence("briefing_preflight", args) do
    with {:ok, _path_raw} <- require_param(args, "path"),
         {:ok, prompt} <- require_param(args, "prompt") do
      path = Giulia.Core.PathMapper.resolve_path(args["path"])
      top_k = parse_int(args["top_k"], 5)
      depth = parse_int(args["depth"], 2)

      case Giulia.Intelligence.Preflight.run(path, prompt, top_k: top_k, depth: depth) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_intelligence("brief_architect", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Intelligence.ArchitectBrief.build(path) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_intelligence("plan_validate", args) do
    with {:ok, _path_raw} <- require_param(args, "path"),
         {:ok, plan} <- require_param(args, "plan") do
      path = Giulia.Core.PathMapper.resolve_path(args["path"])

      case Giulia.Intelligence.PlanValidator.validate(path, plan) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_intelligence("report_rules", _args) do
    host_path =
      case System.get_env("GIULIA_HOST_HOME") do
        nil -> "~/.claude/REPORT_RULES.md"
        "" -> "~/.claude/REPORT_RULES.md"
        home -> Path.join([home, ".claude", "REPORT_RULES.md"])
      end

    content =
      ["/projects/Giulia/docs/REPORT_RULES.md"]
      |> Enum.find_value(fn path ->
        case File.read(path) do
          {:ok, text} -> text
          _ -> nil
        end
      end)

    {:ok, %{host_path: host_path, content: content}}
  end

  defp dispatch_intelligence(sub, _args), do: {:error, "Unknown intelligence tool: #{sub}"}

  # ============================================================================
  # Transaction Dispatch (3 tools)
  # ============================================================================

  defp dispatch_transaction("enable", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Core.ContextManager.get_context(path) do
        {:ok, pid} ->
          new_mode = Giulia.Core.ProjectContext.toggle_transaction_preference(pid)
          {:ok, %{transaction_mode: new_mode, path: path}}

        {:needs_init, _} ->
          {:error, "Project not initialized. Run index/scan first."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_transaction("staged", args) do
    path = if args["path"], do: Giulia.Core.PathMapper.resolve_path(args["path"]), else: nil

    if path do
      case Giulia.Core.ContextManager.get_context(path) do
        {:ok, pid} ->
          pref = Giulia.Core.ProjectContext.transaction_preference(pid)
          {:ok, %{transaction_mode: pref, staged_files: [], path: path}}

        {:needs_init, _} ->
          {:ok, %{transaction_mode: false, staged_files: [], path: path}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:ok, %{transaction_mode: false, staged_files: []}}
    end
  end

  defp dispatch_transaction("rollback", args) do
    with {:ok, path} <- require_path(args) do
      case Giulia.Core.ContextManager.get_context(path) do
        {:ok, pid} ->
          pref = Giulia.Core.ProjectContext.transaction_preference(pid)

          if pref do
            Giulia.Core.ProjectContext.toggle_transaction_preference(pid)
            {:ok, %{status: "reset", transaction_mode: false, path: path}}
          else
            {:ok, %{status: "already_off", transaction_mode: false, path: path}}
          end

        {:needs_init, _} ->
          {:error, "Project not initialized."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp dispatch_transaction(sub, _args), do: {:error, "Unknown transaction tool: #{sub}"}

  # ============================================================================
  # Approval Dispatch (2 tools)
  # ============================================================================

  defp dispatch_approval("respond", args) do
    with {:ok, approval_id} <- require_param(args, "approval_id") do
      approved = args["approved"] == true or args["approved"] == "true"

      case Giulia.Inference.Approval.respond(approval_id, approved) do
        :ok -> {:ok, %{status: "responded", approval_id: approval_id, approved: approved}}
        {:error, :not_found} -> {:error, "Approval request not found: #{approval_id}"}
      end
    end
  end

  defp dispatch_approval("get_pending", args) do
    with {:ok, approval_id} <- require_param(args, "approval_id") do
      case Giulia.Inference.Approval.get_pending(approval_id) do
        {:ok, request} -> {:ok, request}
        {:error, :not_found} -> {:error, "Approval request not found: #{approval_id}"}
      end
    end
  end

  defp dispatch_approval(sub, _args), do: {:error, "Unknown approval tool: #{sub}"}

  # ============================================================================
  # Monitor Dispatch (4 MCP-compatible tools, excluding HTML and SSE)
  # ============================================================================

  defp dispatch_monitor("history", args) do
    n = parse_int(args["n"], 50)
    events = Giulia.Monitor.Store.history(n)
    {:ok, %{events: events, count: length(events)}}
  end

  defp dispatch_monitor("observe_start", args) do
    case Giulia.Runtime.Observer.start_observing(args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp dispatch_monitor("observe_stop", args) do
    case Giulia.Runtime.Observer.stop_observing(args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp dispatch_monitor("observe_status", _args) do
    result = Giulia.Runtime.Observer.observation_status()
    {:ok, result}
  end

  defp dispatch_monitor(sub, _args), do: {:error, "Unknown monitor tool: #{sub}"}

  # ============================================================================
  # Discovery Dispatch (4 tools)
  # ============================================================================

  defp dispatch_discovery("skills", args) do
    skills =
      ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())

    filtered =
      case args["category"] do
        nil -> skills
        cat -> Enum.filter(skills, &(&1.category == cat))
      end

    {:ok, %{skills: filtered, count: length(filtered)}}
  end

  defp dispatch_discovery("categories", _args) do
    categories =
      ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, skills} -> %{category: cat, count: length(skills)} end)
      |> Enum.sort_by(& &1.category)

    {:ok, %{categories: categories, total: length(categories)}}
  end

  defp dispatch_discovery("search", args) do
    with {:ok, q} <- require_param(args, "q") do
      q_lower = String.downcase(q)

      matches =
        ToolSchema.routers()
        |> Enum.flat_map(& &1.__skills__())
        |> Enum.filter(fn skill -> String.contains?(String.downcase(skill.intent), q_lower) end)

      {:ok, %{skills: matches, count: length(matches), query: q}}
    end
  end

  defp dispatch_discovery("report_rules", _args) do
    dispatch_intelligence("report_rules", %{})
  end

  defp dispatch_discovery(sub, _args), do: {:error, "Unknown discovery tool: #{sub}"}

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp register_all_tools(frame) do
    ToolSchema.all_tools()
    |> Enum.reduce(frame, fn tool_def, acc ->
      Anubis.Server.Frame.register_tool(acc, tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema
      )
    end)
  end

  defp execute(frame, fun) do
    task = Task.Supervisor.async_nolink(Giulia.TaskSupervisor, fun)

    case Task.yield(task, @tool_timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:reply, Response.tool() |> Response.text(Jason.encode!(result, pretty: true)), frame}

      {:ok, {:error, message}} when is_binary(message) ->
        {:reply, Response.tool() |> Response.error(message), frame}

      {:ok, {:error, reason}} ->
        {:reply, Response.tool() |> Response.error(inspect(reason)), frame}

      nil ->
        {:reply, Response.tool() |> Response.error("Tool execution timed out"), frame}

      {:exit, reason} ->
        {:reply, Response.tool() |> Response.error("Tool crashed: #{inspect(reason)}"), frame}
    end
  rescue
    e ->
      {:reply, Response.tool() |> Response.error("Tool error: #{Exception.message(e)}"), frame}
  end

  defp require_path(args) do
    case args["path"] do
      nil -> {:error, "Missing required parameter: path"}
      path -> {:ok, Giulia.Core.PathMapper.resolve_path(path)}
    end
  end

  defp require_param(args, name) do
    case args[name] do
      nil -> {:error, "Missing required parameter: #{name}"}
      val -> {:ok, val}
    end
  end

  defp resolve_node(nil), do: :local
  defp resolve_node(""), do: :local

  defp resolve_node(node_str) do
    case Giulia.Daemon.Helpers.safe_to_node_atom(node_str) do
      {:ok, atom} -> atom
      {:error, _} -> :local
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp parse_float(nil, default), do: default

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(_, default), do: default

  defp parse_suppress(nil), do: %{}
  defp parse_suppress(""), do: %{}

  defp parse_suppress(raw) when is_binary(raw) do
    raw
    |> String.split(";")
    |> Enum.reduce(%{}, fn entry, acc ->
      case String.split(entry, ":", parts: 2) do
        [rule, modules] ->
          module_list = modules |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          if module_list != [], do: Map.put(acc, rule, module_list), else: acc

        _ ->
          acc
      end
    end)
  end

  defp parse_suppress(_), do: %{}

  defp format_fracture(frac) do
    %{
      implementer: Map.get(frac, :implementer, "unknown"),
      missing: Map.get(frac, :missing, []),
      injected: Map.get(frac, :injected, []),
      optional_omitted: Map.get(frac, :optional_omitted, []),
      heuristic_injected: Map.get(frac, :heuristic_injected, [])
    }
  end

  defp simple_knowledge_call(args, func_name) do
    with {:ok, path} <- require_path(args) do
      case apply(Giulia.Knowledge.Store, func_name, [path]) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, "#{func_name} failed: #{inspect(reason)}"}
      end
    end
  end
end
