defmodule Giulia.MCP.Dispatch.Knowledge do
  @moduledoc """
  MCP dispatch handlers for the `knowledge_*` tool family.

  The largest dispatch surface — wraps `Giulia.Knowledge.Store` analytics
  (graph traversal, dead-code, heatmap, behaviour integrity, change risk,
  topology, conventions, etc.). The bucket-3 endpoints (impact, style_oracle,
  unprotected_hubs, duplicates) route through `Giulia.Knowledge.Facade` for
  shared resolution/readiness/coercion.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Knowledge.Store
  alias Giulia.Persistence.Verifier, as: L2Verifier
  alias Giulia.Storage.Arcade.Verifier, as: ArcadeVerifier

  @spec stats(map()) :: {:ok, map()} | {:error, String.t()}
  def stats(args) do
    with {:ok, path} <- require_path(args) do
      stats = Store.stats(path)
      hubs = Enum.map(stats.hubs || [], fn {name, degree} -> %{module: name, degree: degree} end)
      {:ok, %{stats | hubs: hubs}}
    end
  end

  @spec dependents(map()) :: {:ok, map()} | {:error, String.t()}
  def dependents(args) do
    # Thin proxy: forward to Store, which backstops a missing/nil module with
    # {:not_found}. The required-ness gate is the REST edge's job (400); MCP
    # does not re-implement it. See docs/orders/*proxy*.
    with {:ok, path} <- require_path(args) do
      module = args["module"]

      case Store.dependents(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependents: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec dependencies(map()) :: {:ok, map()} | {:error, String.t()}
  def dependencies(args) do
    # Thin proxy: Store.dependencies backstops a nil module with {:not_found}
    # (topology.ex:94 has_vertex? guard — same path as dependents). Required-ness
    # is the REST edge's job.
    with {:ok, path} <- require_path(args) do
      module = args["module"]

      case Store.dependencies(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependencies: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec centrality(map()) :: {:ok, map()} | {:error, String.t()}
  def centrality(args) do
    # Thin proxy: Store.centrality backstops a nil module with {:not_found}
    # (topology.ex has_vertex? guard). Required-ness is the REST edge's job.
    with {:ok, path} <- require_path(args) do
      module = args["module"]

      case Store.centrality(path, module) do
        {:ok, result} -> {:ok, Map.put(result, :module, module)}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec impact(map()) :: {:ok, map()} | {:error, String.t()}
  def impact(args) do
    # Readiness now via the shared facade step (the (a) behavior change): MCP
    # gains the actionable not-ready signal it lacked, rendered as a binary
    # string carrying the scan hint (Server renders binary {:error,_} verbatim).
    # Module gate STAYS after readiness (not bucket-1 redundant): Store.impact_map
    # crashes on nil module (String.downcase, topology.ex), unlike dependents.
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        with {:ok, _module} <- require_param(args, "module") do
          case Giulia.Knowledge.Facade.impact(path, args) do
            {:ok, result} ->
              {:ok, result}

            {:error,
             {:not_found, %{module: module, suggestions: suggestions, graph_info: graph_info}}} ->
              {:error,
               "Module not found in graph: #{module}. Suggestions: #{inspect(suggestions)}. Graph: #{inspect(graph_info)}"}
          end
        end
    end
  end

  @spec integrity(map()) :: {:ok, map()} | {:error, String.t()}
  def integrity(args) do
    with {:ok, path} <- require_path(args) do
      Store.integrity_report(path)
    end
  end

  @spec dead_code(map()) :: {:ok, term()} | {:error, String.t()}
  def dead_code(args) do
    with {:ok, path} <- require_path(args) do
      case Store.find_dead_code(path, relevance: args["relevance"]) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, "find_dead_code failed: #{inspect(reason)}"}
      end
    end
  end

  @spec cycles(map()) :: {:ok, term()} | {:error, String.t()}
  def cycles(args), do: simple_call(args, :find_cycles)

  @spec god_modules(map()) :: {:ok, term()} | {:error, String.t()}
  def god_modules(args), do: simple_call(args, :find_god_modules)

  @spec orphan_specs(map()) :: {:ok, term()} | {:error, String.t()}
  def orphan_specs(args), do: simple_call(args, :find_orphan_specs)

  @spec fan_in_out(map()) :: {:ok, term()} | {:error, String.t()}
  def fan_in_out(args), do: simple_call(args, :find_fan_in_out)

  @spec coupling(map()) :: {:ok, term()} | {:error, String.t()}
  def coupling(args), do: simple_call(args, :find_coupling)

  @spec api_surface(map()) :: {:ok, term()} | {:error, String.t()}
  def api_surface(args), do: simple_call(args, :find_api_surface)

  @spec change_risk(map()) :: {:ok, term()} | {:error, String.t()}
  def change_risk(args), do: simple_call(args, :change_risk_score)

  @spec heatmap(map()) :: {:ok, term()} | {:error, String.t()}
  def heatmap(args), do: simple_call(args, :heatmap)

  @spec path(map()) :: {:ok, map()} | {:error, String.t()}
  def path(args) do
    with {:ok, path} <- require_path(args),
         {:ok, from} <- require_param(args, "from"),
         {:ok, to} <- require_param(args, "to") do
      case Store.trace_path(path, from, to) do
        {:ok, :no_path} -> {:ok, %{from: from, to: to, path: nil, message: "No path found"}}
        {:ok, trace} -> {:ok, %{from: from, to: to, path: trace, hops: length(trace) - 1}}
        {:error, {:not_found, vertex}} -> {:error, "Vertex not found in graph: #{vertex}"}
      end
    end
  end

  @spec logic_flow(map()) :: {:ok, map()} | {:error, String.t()}
  def logic_flow(args) do
    with {:ok, path} <- require_path(args),
         {:ok, from} <- require_param(args, "from"),
         {:ok, to} <- require_param(args, "to") do
      case Store.logic_flow(path, from, to) do
        {:ok, :no_path} ->
          {:ok, %{from: from, to: to, steps: nil, hop_count: 0, message: "No path found"}}

        {:ok, steps} ->
          {:ok, %{from: from, to: to, steps: steps, hop_count: max(length(steps) - 1, 0)}}

        {:error, {:not_found, vertex}} ->
          {:error, "MFA vertex not found in graph: #{vertex}"}
      end
    end
  end

  @spec style_oracle(map()) :: {:ok, term()} | {:error, String.t()}
  def style_oracle(args) do
    # Readiness via the shared edge; q gate STAYS (Store.style_oracle embeds the
    # query — not nil-safe). top_k coercion lives in the facade.
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        with {:ok, _q} <- require_param(args, "q") do
          case Giulia.Knowledge.Facade.style_oracle(path, args) do
            {:ok, result} ->
              {:ok, result}

            {:error, "Semantic search unavailable" <> _} ->
              {:error, "Semantic search unavailable. EmbeddingServing not loaded."}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
    end
  end

  @spec pre_impact_check(map()) :: {:ok, term()} | {:error, String.t()}
  def pre_impact_check(args) do
    # Thin proxy: forward the param map to Store, which validates module/action
    # and returns {:unknown_action}/{:not_found}/{:invalid_target}. MCP does not
    # re-implement the required-ness gate; REST keeps its own 400 edge.
    with {:ok, path} <- require_path(args) do
      case Giulia.Knowledge.Facade.pre_impact_check(path, args) do
        {:ok, result} ->
          {:ok, result}

        {:error, {:not_found, vertex}} ->
          {:error, "Vertex not found in graph: #{vertex}"}

        {:error, {:unknown_action, act}} ->
          {:error, "Unknown action: #{act}. Use: rename_function, remove_function, rename_module"}

        {:error, {:invalid_target, target}} ->
          {:error, "Invalid target format: #{target}. Use: func_name/arity"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @spec unprotected_hubs(map()) :: {:ok, term()} | {:error, String.t()}
  def unprotected_hubs(args) do
    # Readiness via the shared edge; threshold coercion lives in the facade.
    # No required param beyond path (both thresholds default).
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        case Giulia.Knowledge.Facade.unprotected_hubs(path, args) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  @spec supervision(map()) :: {:ok, term()} | {:error, String.t()}
  def supervision(args) do
    # Thin renderer over the same facade call the REST route makes — the tree
    # is built once, in business logic, not assembled per protocol.
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        # The facade returns `{:ok, map()}` unconditionally — the tree is
        # whatever the build holds, and an empty graph is an empty tree, not an
        # error. No error branch to render.
        Giulia.Knowledge.Facade.supervision(path, args)
    end
  end

  @spec struct_lifecycle(map()) :: {:ok, term()} | {:error, String.t()}
  def struct_lifecycle(args) do
    with {:ok, path} <- require_path(args) do
      struct_filter = args["struct"]

      case Store.struct_lifecycle(path, struct_filter) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @spec duplicates(map()) :: {:ok, term()} | {:error, String.t()}
  def duplicates(args) do
    # Two readiness dimensions: scan-readiness via the shared edge, and
    # embedding-availability inside the facade. The embedding-unavailable signal
    # reaches the agent as the actionable "query the worker" message (binary).
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        case Giulia.Knowledge.Facade.duplicates(path, args) do
          {:ok, result} ->
            {:ok, result}

          {:error, :embedding_unavailable} ->
            {:error, Giulia.Knowledge.Facade.embedding_unavailable_message()}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  @spec audit(map()) :: {:ok, map()} | {:error, String.t()}
  def audit(args) do
    with {:ok, path} <- require_path(args) do
      Store.audit(path)
    end
  end

  @spec topology(map()) :: {:ok, map()} | {:error, String.t()}
  def topology(args) do
    with {:ok, path} <- require_path(args) do
      Store.topology_view(path)
    end
  end

  @spec conventions(map()) :: {:ok, term()} | {:error, String.t()}
  def conventions(args) do
    with {:ok, path} <- require_path(args) do
      suppress = Giulia.Daemon.Helpers.parse_suppress(args["suppress"])
      opts = [suppress: suppress, relevance: args["relevance"]]
      opts = if args["module"], do: Keyword.put(opts, :module, args["module"]), else: opts

      case Store.find_conventions(path, opts) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, "conventions failed: #{inspect(reason)}"}
      end
    end
  end

  @spec verify_l2(map()) :: {:ok, map()} | {:error, String.t()}
  def verify_l2(args) do
    with {:ok, path} <- require_path(args) do
      L2Verifier.verify_l2(path,
        sample_per_label: parse_int(args["sample_per_label"], 10),
        check: args["check"] || "all"
      )
    end
  end

  @spec verify_l3(map()) :: {:ok, term()} | {:error, String.t()}
  def verify_l3(args) do
    with {:ok, path} <- require_path(args) do
      sample = parse_int(args["sample_per_bucket"], 10)

      case ArcadeVerifier.verify(path, sample_per_bucket: sample) do
        {:ok, report} -> {:ok, report}
        {:error, reason} -> {:error, "verify failed: #{inspect(reason)}"}
      end
    end
  end

  defp simple_call(args, func_name) do
    with {:ok, path} <- require_path(args) do
      case apply(Store, func_name, [path]) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, "#{func_name} failed: #{inspect(reason)}"}
      end
    end
  end
end
