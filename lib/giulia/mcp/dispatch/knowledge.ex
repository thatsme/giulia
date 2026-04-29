defmodule Giulia.MCP.Dispatch.Knowledge do
  @moduledoc """
  MCP dispatch handlers for the `knowledge_*` tool family.

  The largest dispatch surface — wraps `Giulia.Knowledge.Store` analytics
  (graph traversal, dead-code, heatmap, behaviour integrity, change risk,
  topology, conventions, etc.) plus a couple of cross-cutting calls into
  `Giulia.Intelligence.SemanticIndex` for duplicate detection.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Intelligence.SemanticIndex
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
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Store.dependents(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependents: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec dependencies(map()) :: {:ok, map()} | {:error, String.t()}
  def dependencies(args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Store.dependencies(path, module) do
        {:ok, deps} -> {:ok, %{module: module, dependencies: deps, count: length(deps)}}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec centrality(map()) :: {:ok, map()} | {:error, String.t()}
  def centrality(args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      case Store.centrality(path, module) do
        {:ok, result} -> {:ok, Map.put(result, :module, module)}
        {:error, {:not_found, _}} -> {:error, "Module not found in graph: #{module}"}
      end
    end
  end

  @spec impact(map()) :: {:ok, map()} | {:error, String.t()}
  def impact(args) do
    with {:ok, path} <- require_path(args),
         {:ok, module} <- require_param(args, "module") do
      depth = parse_int(args["depth"], 2)

      case Store.impact_map(path, module, depth) do
        {:ok, result} ->
          upstream = Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end)
          downstream = Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end)

          func_edges =
            Enum.map(result.function_edges, fn {name, targets} ->
              %{function: name, calls: targets}
            end)

          {:ok,
           %{result | upstream: upstream, downstream: downstream, function_edges: func_edges}}

        {:error, {:not_found, _, suggestions, graph_info}} ->
          {:error,
           "Module not found in graph: #{module}. Suggestions: #{inspect(suggestions)}. Graph: #{inspect(graph_info)}"}
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
    with {:ok, path} <- require_path(args),
         {:ok, q} <- require_param(args, "q") do
      top_k = parse_int(args["top_k"], 3)

      case Store.style_oracle(path, q, top_k) do
        {:ok, result} ->
          {:ok, result}

        {:error, "Semantic search unavailable" <> _} ->
          {:error, "Semantic search unavailable. EmbeddingServing not loaded."}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @spec pre_impact_check(map()) :: {:ok, term()} | {:error, String.t()}
  def pre_impact_check(args) do
    with {:ok, path} <- require_path(args),
         {:ok, _module} <- require_param(args, "module"),
         {:ok, _action} <- require_param(args, "action") do
      case Store.pre_impact_check(path, args) do
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
    with {:ok, path} <- require_path(args) do
      hub_threshold = parse_int(args["hub_threshold"], 3)
      spec_threshold = parse_float(args["spec_threshold"], 0.5)

      case Store.find_unprotected_hubs(path,
             hub_threshold: hub_threshold,
             spec_threshold: spec_threshold
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
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
    with {:ok, path} <- require_path(args) do
      threshold = parse_float(args["threshold"], 0.85)
      max_clusters = parse_int(args["max"], 20)

      case SemanticIndex.find_duplicates(path,
             threshold: threshold,
             max: max_clusters,
             relevance: args["relevance"]
           ) do
        {:ok, result} ->
          {:ok, result}

        {:error, "Semantic search unavailable" <> _} ->
          {:error, "Semantic search unavailable. EmbeddingServing not loaded."}

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
      suppress = parse_suppress(args["suppress"])
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
