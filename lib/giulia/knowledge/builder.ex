defmodule Giulia.Knowledge.Builder do
  @moduledoc """
  Knowledge Graph Construction — Pure Functions.

  Builds a directed graph from AST data (modules, functions, imports, structs,
  callbacks). Runs 5 passes: vertices, dependency edges, xref call edges,
  AST-based function-call edges, and edge promotion (MFA→module + defdelegate).

  This module is intentionally stateless — it takes AST data and returns a
  `Graph.t()`. The Store GenServer spawns graph construction in a Task so the
  mailbox stays responsive to queries while the CPU does heavy AST traversal.
  """

  require Logger

  @doc """
  Build a complete knowledge graph from AST data.

  Takes `%{file_path => ast_data_map}` as produced by `Context.Store.all_asts/1`.
  Returns a `Graph.t()` with vertices (modules, functions, structs, behaviours)
  and edges (depends_on, calls, implements).
  """
  @spec build_graph(%{String.t() => map()}) :: Graph.t()
  def build_graph(ast_data) do
    graph = Graph.new(type: :directed)

    # Collect all module names for cross-referencing
    all_modules =
      ast_data
      |> Enum.flat_map(fn {_path, data} ->
        Enum.map(data[:modules] || [], & &1.name)
      end)
      |> MapSet.new()

    # Pass 1: Add vertices
    graph = Enum.reduce(ast_data, graph, fn {_path, data}, g ->
      g
      |> add_module_vertices(data)
      |> add_function_vertices(data)
      |> add_struct_vertices(data)
      |> add_behaviour_vertices(data)
    end)

    # Pass 2: Add edges
    graph = Enum.reduce(ast_data, graph, fn {_path, data}, g ->
      g
      |> add_dependency_edges(data, all_modules)
      |> add_implements_edges(data, all_modules)
    end)

    # Pass 3: Add xref call edges (if target project has compiled BEAM files)
    project_root = infer_project_root(ast_data)
    graph = add_xref_edges(graph, project_root)

    # Pass 4: Function-level call edges (AST-based)
    # Walks each function body to find calls to other project functions,
    # creating MFA→MFA edges like "Mod.foo/2" → "Other.bar/1"
    graph = add_function_call_edges(graph, ast_data, all_modules)

    # Pass 5: Promote function-level edges to module-level edges
    # Collapses MFA→MFA :calls edges into Module→Module :calls edges,
    # catching fully-qualified calls that bypass alias/import.
    # Also detects defdelegate targets as module dependencies.
    graph =
      graph
      |> promote_function_edges_to_module(all_modules)
      |> add_defdelegate_edges(ast_data, all_modules)

    # Pass 6: Module-reference edges — catches modules passed as atom args to
    # framework macros (Phoenix router `get("/x", Controller, :action)`, Plug
    # `plug(Auth)`, supervision `children = [Endpoint]`, struct literals
    # `%Foo{}`). These aren't call-shaped, so passes 3-5 miss them.
    # Labeled `:references` (distinct from `:depends_on`/`:calls`) so
    # queries can filter it out for pure architectural views.
    graph = add_reference_edges(graph, ast_data, all_modules)

    # Pass 7: Protocol-dispatch edges — synthesizes {:calls, :protocol_impl}
    # edges from a protocol module to each function in its `defimpl` modules.
    # `Jason.encode(%Plausible.Goal{})` would otherwise look like a dead-end
    # to the static call graph because the dispatcher is compile-time
    # generated. This pass produces the edge the static call graph couldn't
    # see, so downstream detectors (dead_code, change_risk, etc.) treat
    # impl functions as live. See `feedback_dispatch_edge_synthesis.md`
    # for the architectural commitment this implements.
    graph = add_protocol_dispatch_edges(graph, ast_data)

    # Pass 8: Behaviour-dispatch edges — synthesizes
    # {:calls, :behaviour_impl} edges from an external-framework behaviour
    # module (GenServer, Mix.Task, Ecto.Type, Phoenix.LiveView, etc.) to
    # each callback function in each implementer. Reuses the static known-
    # behaviours map in `Knowledge.Behaviours` as the source of truth for
    # callback signatures; only emits edges for callbacks the implementer
    # actually defines.
    graph = add_behaviour_dispatch_edges(graph, ast_data)

    # Pass 9: Phoenix router-dispatch edges — parses route DSL calls
    # (`get "/path", Controller, :action`, `resources "/path", Controller`,
    # etc.) and synthesizes `{:calls, :router_dispatch}` edges from the
    # router module to each controller action. Controller actions are
    # runtime-dispatched by the Phoenix.Router; without this pass they
    # appear as dead-end vertices in the static call graph. Action arity
    # is assumed 2 (the Phoenix convention: `def action(conn, params)`).
    add_router_dispatch_edges(graph, ast_data)
  end

  # ============================================================================
  # Pass 1: Vertices
  # ============================================================================

  defp add_module_vertices(graph, data) do
    modules = data[:modules] || []

    Enum.reduce(modules, graph, fn mod, g ->
      Graph.add_vertex(g, mod.name, :module)
    end)
  end

  defp add_function_vertices(graph, data) do
    functions = data[:functions] || []

    # Each function carries its own enclosing module name in
    # `func.module` (populated by the traversal-based extractor).
    # Fall back to the file's first module for AST data that predates
    # the :module field (tests that build function_info maps by hand,
    # cached CubDB entries written before the traversal refactor).
    # Functions with no resolvable owner are skipped — a function
    # without a module can't produce a qualified vertex.
    fallback_module =
      case data[:modules] do
        [%{name: name} | _] -> name
        _ -> nil
      end

    Enum.reduce(functions, graph, fn func, g ->
      module_name = Map.get(func, :module) || fallback_module

      cond do
        module_name in [nil, "Unknown"] ->
          g

        true ->
          # Default args emit a vertex per arity from min_arity..arity.
          min_arity = Map.get(func, :min_arity, func.arity)

          Enum.reduce(min_arity..func.arity, g, fn arity, g_acc ->
            vertex_id = "#{module_name}.#{func.name}/#{arity}"
            Graph.add_vertex(g_acc, vertex_id, :function)
          end)
      end
    end)
  end

  defp add_struct_vertices(graph, data) do
    structs = data[:structs] || []

    Enum.reduce(structs, graph, fn struct_info, g ->
      Graph.add_vertex(g, struct_info.module, :struct)
    end)
  end

  defp add_behaviour_vertices(graph, data) do
    callbacks = data[:callbacks] || []
    modules = data[:modules] || []

    if callbacks != [] do
      case modules do
        [first | _] ->
          Graph.add_vertex(graph, first.name, :behaviour)
        _ ->
          graph
      end
    else
      graph
    end
  end

  # ============================================================================
  # Pass 2: Dependency & Implementation Edges
  # ============================================================================

  defp add_dependency_edges(graph, data, all_modules) do
    modules = data[:modules] || []
    imports = data[:imports] || []

    case modules do
      [source_mod | _] ->
        # ALL import types (import, alias, use, require) indicate a dependency
        Enum.reduce(imports, graph, fn imp, g ->
          # Only add edges to modules that exist in our project
          if MapSet.member?(all_modules, imp.module) and imp.module != source_mod.name do
            Graph.add_edge(g, source_mod.name, imp.module, label: :depends_on)
          else
            g
          end
        end)

      _ ->
        graph
    end
  end

  defp add_implements_edges(graph, data, all_modules) do
    modules = data[:modules] || []
    imports = data[:imports] || []

    case modules do
      [source_mod | _] ->
        # @behaviour / use directives indicate implementation
        behaviour_imports =
          Enum.filter(imports, fn imp ->
            imp.type in [:use, :require] and MapSet.member?(all_modules, imp.module)
          end)

        Enum.reduce(behaviour_imports, graph, fn imp, g ->
          if imp.module != source_mod.name do
            Graph.add_edge(g, source_mod.name, imp.module, label: :implements)
          else
            g
          end
        end)

      _ ->
        graph
    end
  end

  # ============================================================================
  # Pass 3: xref Call Edges
  # ============================================================================

  defp add_xref_edges(graph, nil) do
    Logger.debug("No project root found, skipping xref call edges")
    graph
  end

  defp add_xref_edges(graph, project_root) do
    beam_dir = find_beam_directory(project_root)

    if beam_dir do
      Logger.info("Found BEAM files at #{beam_dir}, running xref analysis")
      run_xref_analysis(graph, beam_dir)
    else
      Logger.debug("No BEAM directory found for #{project_root}, skipping xref call edges")
      graph
    end
  end

  defp find_beam_directory(project_root) do
    # Derive the app name from mix.exs or fall back to directory name
    app_name = infer_app_name(project_root)

    # Giulia-managed per-project build path (set by ensure_compiled in Indexer)
    giulia_build = giulia_build_path(project_root)

    candidates =
      [
        # Giulia-managed compilation output (per-project, isolated)
        Path.join([giulia_build, "lib", app_name, "ebin"]),
        # Standard mix build (dev)
        Path.join([project_root, "_build", "dev", "lib", app_name, "ebin"]),
        # Standard mix build (prod)
        Path.join([project_root, "_build", "prod", "lib", app_name, "ebin"]),
        # Standard mix build (test)
        Path.join([project_root, "_build", "test", "lib", app_name, "ebin"])
      ]

    Enum.find(candidates, &File.dir?/1)
  end

  # Per-project build path for xref BEAM files.
  # Must match the path used by Giulia.Context.Indexer.ensure_compiled/1.
  defp giulia_build_path(project_path) do
    hash =
      :crypto.hash(:md5, project_path)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    Path.join(["/tmp/giulia_build", "targets", hash])
  end

  # Infer the project root from AST file paths (common prefix of all source files)
  defp infer_project_root(ast_data) do
    paths = Map.keys(ast_data)

    case paths do
      [] -> nil
      [single] -> single |> Path.dirname() |> strip_lib_suffix()
      _ ->
        paths
        |> Enum.map(&Path.split/1)
        |> Enum.reduce(fn parts, acc ->
          Enum.zip(acc, parts)
          |> Enum.take_while(fn {a, b} -> a == b end)
          |> Enum.map(&elem(&1, 0))
        end)
        |> Path.join()
        |> strip_lib_suffix()
    end
  end

  defp strip_lib_suffix(path) do
    if String.ends_with?(path, "/lib") or String.ends_with?(path, "\\lib") do
      Path.dirname(path)
    else
      path
    end
  end

  # Infer app name from mix.exs or directory name
  defp infer_app_name(project_root) do
    mix_path = Path.join(project_root, "mix.exs")

    case File.read(mix_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> Path.basename(project_root)
        end
      _ -> Path.basename(project_root)
    end
  end

  defp run_xref_analysis(graph, beam_dir) do
    try do
      # Dynamic calls to :xref to avoid compile warnings
      # (xref is in the Erlang 'tools' app, may not be available at compile time)
      xref_mod = :xref

      {:ok, xref} = apply(xref_mod, :start, [:giulia_xref, [{:xref_mode, :modules}]])

      apply(xref_mod, :add_directory, [xref, String.to_charlist(beam_dir)])

      case apply(xref_mod, :q, [xref, ~c"ME"]) do
        {:ok, calls} ->
          Logger.info("xref found #{length(calls)} module-level call edges")
          graph = add_module_call_edges(graph, calls)
          apply(xref_mod, :stop, [xref])
          graph

        {:error, _xref_mod, reason} ->
          Logger.warning("xref query failed: #{inspect(reason)}")
          apply(xref_mod, :stop, [xref])
          graph
      end
    rescue
      e ->
        Logger.debug("xref analysis failed: #{Exception.message(e)}")
        graph
    catch
      _, reason ->
        Logger.debug("xref analysis error: #{inspect(reason)}")
        graph
    end
  end

  # Add module-level call edges from xref results
  # xref ME query returns [{CallerMod, CalleeMod}]
  defp add_module_call_edges(graph, calls) when is_list(calls) do
    Enum.reduce(calls, graph, fn {caller_mod, callee_mod}, g ->
      caller = String.replace_leading(Atom.to_string(caller_mod), "Elixir.", "")
      callee = String.replace_leading(Atom.to_string(callee_mod), "Elixir.", "")

      if Graph.has_vertex?(g, caller) and Graph.has_vertex?(g, callee) and caller != callee do
        Graph.add_edge(g, caller, callee, label: {:calls, :xref})
      else
        g
      end
    end)
  end

  defp add_module_call_edges(graph, _), do: graph

  # ============================================================================
  # Pass 4: Function-Level Call Edges (AST-based)
  # ============================================================================

  defp add_function_call_edges(graph, ast_data, all_modules) do
    Enum.reduce(ast_data, graph, fn {path, data}, g ->
      # Build alias map for this file — the multi-segment fix is
      # resolved inside `extract_calls_from_body` via `resolve_alias/2`.
      alias_map =
        (data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :alias end)
        |> Map.new(fn imp ->
          short = imp.module |> String.split(".") |> List.last()
          {short, imp.module}
        end)

      source =
        case File.read(path) do
          {:ok, content} -> content
          _ -> ""
        end

      case Sourceror.parse_string(source) do
        {:ok, ast} ->
          fallback_caller =
            case data[:modules] do
              [%{name: name} | _] -> name
              _ -> "Unknown"
            end

          extract_calls_per_function(g, ast, fallback_caller, alias_map, all_modules)

        _ ->
          g
      end
    end)
  end

  # Walk the AST with an enclosing-module stack so def/defp nodes are
  # attributed to their real enclosing `defmodule` — not the file's
  # first module. Previously all def nodes inherited `caller_module =
  # data[:modules] |> List.first().name`, which silently miscounted
  # call-edges in every file with multiple top-level defmodules
  # (Plausible.HTTPClient had 3, so every private-helper call became
  # a non-matching MFA and no edges landed in the graph).
  defp extract_calls_per_function(graph, ast, fallback_caller, alias_map, all_modules) do
    {_ast, {func_call_map, _stack}} =
      Macro.traverse(
        ast,
        {%{}, []},
        fn node, {acc, stack} = state ->
          case def_module_local_name(node) do
            {:ok, local_name} ->
              {node, {acc, [join_module_name(stack, local_name) | stack]}}

            :skip ->
              current_caller = List.first(stack) || fallback_caller

              case def_node_signature(node) do
                {:ok, func_name, arity, body} ->
                  caller_mfa = "#{current_caller}.#{func_name}/#{arity}"
                  calls = extract_calls_from_body(body, current_caller, alias_map, all_modules)
                  {node, {merge_calls(acc, caller_mfa, calls), stack}}

                :skip ->
                  {node, state}
              end
          end
        end,
        fn node, {acc, stack} = state ->
          case def_module_local_name(node) do
            {:ok, _} ->
              case stack do
                [_ | rest] -> {node, {acc, rest}}
                [] -> {node, {acc, []}}
              end

            :skip ->
              {node, state}
          end
        end
      )

    # Add edges for all discovered caller→callee relationships.
    # Each edge is labeled {:calls, via} where via ∈ :direct | :alias_resolved
    # | :erlang_atom | :local, recording how the target module resolved at
    # extraction time. Used by the stratified sample-identity check in L3.
    Enum.reduce(func_call_map, graph, fn {caller_mfa, call_targets}, g ->
      if Graph.has_vertex?(g, caller_mfa) do
        Enum.reduce(call_targets, g, fn {target_mfa, via}, g2 ->
          if target_mfa != caller_mfa and Graph.has_vertex?(g2, target_mfa) do
            Graph.add_edge(g2, caller_mfa, target_mfa, label: {:calls, via})
          else
            g2
          end
        end)
      else
        g
      end
    end)
  end

  # Narrow helpers for the module-stack traversal. Kept separate from
  # `Giulia.AST.Extraction.module_node_info/1` because we only need the
  # local name here — not body, line, or impl_for.
  defp def_module_local_name({:defmodule, _, [{:__aliases__, _, parts} | _]}) when is_list(parts) do
    {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}
  end

  defp def_module_local_name({:defmodule, _, [atom | _]}) when is_atom(atom) do
    {:ok, Atom.to_string(atom)}
  end

  defp def_module_local_name({:defprotocol, _, [{:__aliases__, _, parts} | _]})
       when is_list(parts) do
    {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}
  end

  defp def_module_local_name({:defimpl, _, [{:__aliases__, _, proto_parts}, [{for_key, type_ast}] | _]})
       when is_list(proto_parts) do
    if for_key == :for or match?({:__block__, _, [:for]}, for_key) do
      proto = proto_parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")

      case builder_type_ast_parts(type_ast) do
        {:ok, type_name} -> {:ok, "#{proto}.#{type_name}"}
        :skip -> :skip
      end
    else
      :skip
    end
  end

  defp def_module_local_name(_), do: :skip

  defp builder_type_ast_parts({:__aliases__, _, parts}) when is_list(parts),
    do: {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}

  defp builder_type_ast_parts({:__block__, _, [{:__aliases__, _, parts}]}) when is_list(parts),
    do: {:ok, parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")}

  defp builder_type_ast_parts(atom) when is_atom(atom), do: {:ok, Atom.to_string(atom)}

  defp builder_type_ast_parts({:__block__, _, [atom]}) when is_atom(atom),
    do: {:ok, Atom.to_string(atom)}

  defp builder_type_ast_parts(_), do: :skip

  defp join_module_name([], local), do: local
  defp join_module_name([top | _], local), do: "#{top}.#{local}"

  # Returns {:ok, func_name, arity, body} for def/defp nodes, :skip otherwise.
  # Handles the two shapes the original prewalk matched:
  # `def foo(args), do: body` and `def foo(args) when guard, do: body`.
  defp def_node_signature({def_type, _meta, [{func_name, _fn_meta, args}, body]})
       when def_type in [:def, :defp] and is_atom(func_name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, func_name, arity, body}
  end

  defp def_node_signature(
         {def_type, _meta, [{:when, _, [{func_name, _fn_meta, args} | _guards]}, body]}
       )
       when def_type in [:def, :defp] and is_atom(func_name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, func_name, arity, body}
  end

  defp def_node_signature(_), do: :skip

  # Mirror of `Metrics.safe_part_to_string/1`. Kept private here so
  # Builder can stand alone — the alternative is a `use` / shared
  # module, which feels heavier than duplicating three clauses.
  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)

  # First-writer-wins merge of per-caller call-target maps.
  defp merge_calls(acc, caller_mfa, new_calls) do
    Map.update(acc, caller_mfa, new_calls, fn existing ->
      Map.merge(existing, new_calls, fn _k, v, _v -> v end)
    end)
  end

  # Walk a function body AST and collect all call targets.
  # Returns %{target_mfa => via} where via ∈ :direct | :alias_resolved
  # | :erlang_atom | :local. First-writer-wins if the same target appears
  # through multiple paths.
  defp extract_calls_from_body(body, caller_module, alias_map, all_modules) do
    {_body, calls} =
      Macro.prewalk(body, %{}, fn
        # Remote call: Module.func(args) — resolve aliases, including
        # multi-segment forms. `alias Plausible.Ingestion` lets a caller
        # write `Ingestion.Request.build(conn)`; parts come through as
        # [:Ingestion, :Request] and the single-segment alias_map lookup
        # on the joined "Ingestion.Request" misses. Instead, resolve
        # the FIRST segment through the alias map and prepend to the rest.
        {{:., _, [{:__aliases__, _meta, parts}, func_name]}, _call_meta, args} = node, acc
        when is_atom(func_name) and is_list(args) ->
          raw_mod = resolve_module_parts(parts, caller_module)
          mod = resolve_alias_prefix(raw_mod, alias_map)

          if MapSet.member?(all_modules, mod) do
            target_mfa = "#{mod}.#{func_name}/#{length(args)}"
            via = if mod == raw_mod, do: :direct, else: :alias_resolved
            {node, Map.put_new(acc, target_mfa, via)}
          else
            {node, acc}
          end

        # Remote call with atom module: :erlang.func(args)
        {{:., _, [mod_atom, func_name]}, _meta, args} = node, acc
        when is_atom(mod_atom) and is_atom(func_name) and is_list(args) ->
          mod = String.replace_leading(Atom.to_string(mod_atom), "Elixir.", "")

          if MapSet.member?(all_modules, mod) do
            target_mfa = "#{mod}.#{func_name}/#{length(args)}"
            {node, Map.put_new(acc, target_mfa, :erlang_atom)}
          else
            {node, acc}
          end

        # Local call: func(args) — same module
        {local_name, _meta, args} = node, acc
        when is_atom(local_name) and is_list(args) and
             local_name not in [:def, :defp, :defmodule, :defmacro, :defmacrop,
                                :if, :unless, :case, :cond, :with, :for, :fn,
                                :quote, :unquote, :import, :alias, :use, :require,
                                :raise, :reraise, :throw, :try, :receive, :send,
                                :spawn, :spawn_link, :super, :__block__, :__aliases__,
                                :@, :&, :|>, :=, :==, :!=, :<, :>, :<=, :>=,
                                :and, :or, :not, :in, :when, :{}, :%{}, :<<>>,
                                :sigil_r, :sigil_s, :sigil_c, :sigil_w] ->
          target_mfa = "#{caller_module}.#{local_name}/#{length(args)}"
          {node, Map.put_new(acc, target_mfa, :local)}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # ============================================================================
  # Pass 5: Promote Function Edges + Defdelegate Detection
  # ============================================================================

  # Collapse MFA→MFA :calls edges into Module→Module :calls edges.
  # If "A.foo/1" → "B.bar/2" exists, ensure A → B exists at module level.
  defp promote_function_edges_to_module(graph, all_modules) do
    module_set = all_modules

    graph
    |> Graph.edges()
    |> Enum.filter(fn edge -> match?({:calls, _}, edge.label) end)
    |> Enum.reduce(graph, fn edge, g ->
      caller_mod = extract_module_from_mfa(edge.v1)
      callee_mod = extract_module_from_mfa(edge.v2)

      if caller_mod && callee_mod &&
         caller_mod != callee_mod &&
         MapSet.member?(module_set, caller_mod) &&
         MapSet.member?(module_set, callee_mod) &&
         Graph.has_vertex?(g, caller_mod) &&
         Graph.has_vertex?(g, callee_mod) &&
         not has_module_edge?(g, caller_mod, callee_mod) do
        Graph.add_edge(g, caller_mod, callee_mod, label: {:calls, :promoted})
      else
        g
      end
    end)
  end

  # Extract module name from MFA string like "Giulia.Role.role/0" → "Giulia.Role".
  # The function-name class includes `?` and `!` so predicate/bang functions
  # (e.g. `valid?/1`, `update!/2`) promote to module-level edges.
  defp extract_module_from_mfa(mfa) when is_binary(mfa) do
    case Regex.run(~r/^(.+)\.[\w!?]+\/\d+$/, mfa) do
      [_, mod] -> mod
      _ -> nil
    end
  end

  defp extract_module_from_mfa(_), do: nil

  # Check if a module-level edge already exists (any label)
  defp has_module_edge?(graph, source, target) do
    graph
    |> Graph.edges(source, target)
    |> Enum.any?()
  end

  # Detect defdelegate targets and add module-level :depends_on edges.
  # defdelegate dispatches to a target module — this is a hard dependency.
  defp add_defdelegate_edges(graph, ast_data, all_modules) do
    Enum.reduce(ast_data, graph, fn {path, data}, g ->
      modules = data[:modules] || []

      case modules do
        [source_mod | _] ->
          source = case File.read(path) do
            {:ok, content} -> content
            _ -> ""
          end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              targets = extract_defdelegate_targets(ast, all_modules)

              Enum.reduce(targets, g, fn target_mod, g2 ->
                if target_mod != source_mod.name and not has_module_edge?(g2, source_mod.name, target_mod) do
                  Graph.add_edge(g2, source_mod.name, target_mod, label: :depends_on)
                else
                  g2
                end
              end)

            _ -> g
          end

        _ -> g
      end
    end)
  end

  # Walk every file's AST and add `:references` edges for any __aliases__
  # atom pointing at another project module that isn't already linked via
  # :depends_on / :implements / :calls. Catches framework wiring that
  # passes modules as atoms to macros (router verbs, plug, supervisor
  # children), struct literals `%Foo{}`, and typespec references.
  defp add_reference_edges(graph, ast_data, all_modules) do
    Enum.reduce(ast_data, graph, fn {path, data}, g ->
      modules = data[:modules] || []

      case modules do
        [source_mod | _] ->
          source_name = source_mod.name

          source =
            case File.read(path) do
              {:ok, content} -> content
              _ -> ""
            end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              refs = extract_module_references(ast, source_name, all_modules)

              Enum.reduce(refs, g, fn target, g2 ->
                if target != source_name and
                     Graph.has_vertex?(g2, target) and
                     not has_module_edge?(g2, source_name, target) do
                  Graph.add_edge(g2, source_name, target, label: :references)
                else
                  g2
                end
              end)

            _ ->
              g
          end

        _ ->
          g
      end
    end)
  end

  # Collect the set of project-module names reachable as __aliases__ atoms
  # anywhere in the AST.
  defp extract_module_references(ast, caller_module, all_modules) do
    prefixes = caller_namespace_prefixes(caller_module)

    {_ast, refs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, _meta, parts} = node, set when is_list(parts) ->
          case resolve_with_fallback(parts, caller_module, prefixes, all_modules) do
            {:ok, mod} -> {node, MapSet.put(set, mod)}
            :not_found -> {node, set}
          end

        node, set ->
          {node, set}
      end)

    refs
  end

  # Resolve __aliases__ parts to a project module. If the direct name isn't
  # in all_modules, try prepending the caller's parent namespaces (deepest
  # first). Handles Phoenix `scope "/", App do ...Controller end`, Ecto
  # `has_many :posts, Post`, and any other same-app short-form references.
  defp resolve_with_fallback(parts, caller_module, prefixes, all_modules) do
    direct = resolve_module_parts(parts, caller_module)

    if MapSet.member?(all_modules, direct) do
      {:ok, direct}
    else
      Enum.find_value(prefixes, :not_found, fn prefix ->
        candidate = "#{prefix}.#{direct}"
        if MapSet.member?(all_modules, candidate), do: {:ok, candidate}, else: nil
      end)
    end
  end

  # Parent-namespace prefixes of a module, deepest first.
  # "AlexClawWeb.Router" → ["AlexClawWeb"]
  # "AlexClaw.Web.Api.Router" → ["AlexClaw.Web.Api", "AlexClaw.Web", "AlexClaw"]
  # "AlexClaw" → []
  defp caller_namespace_prefixes(caller_module) do
    parts = String.split(caller_module, ".")

    case length(parts) do
      n when n <= 1 -> []
      n -> for i <- (n - 1)..1//-1, do: parts |> Enum.take(i) |> Enum.join(".")
    end
  end

  # Walk AST to find defdelegate ... to: Module targets
  defp extract_defdelegate_targets(ast, all_modules) do
    {_ast, targets} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:defdelegate, _meta, [_call, [to: {:__aliases__, _, parts}]]} = node, set ->
          mod = Enum.map_join(parts, ".", &Atom.to_string/1)
          if MapSet.member?(all_modules, mod) do
            {node, MapSet.put(set, mod)}
          else
            {node, set}
          end

        node, set ->
          {node, set}
      end)

    targets
  end

  # Resolve __MODULE__ AST tuples in alias parts to the enclosing module name.
  # Sourceror represents `__MODULE__.Foo` as [{:__MODULE__, meta, nil}, :Foo].
  # `raw_mod` is the dot-joined name as written at the call site.
  # Split on the first dot, look the prefix up in the alias map, and
  # prepend the resolved form to the suffix if present. Falls back to
  # `raw_mod` when the prefix isn't aliased.
  defp resolve_alias_prefix(raw_mod, alias_map) do
    case String.split(raw_mod, ".", parts: 2) do
      [first] ->
        Map.get(alias_map, first, raw_mod)

      [first, rest] ->
        case Map.get(alias_map, first) do
          nil -> raw_mod
          full -> "#{full}.#{rest}"
        end
    end
  end

  defp resolve_module_parts(parts, caller_module) do
    parts
    |> Enum.map(fn
      {:__MODULE__, _meta, _} -> caller_module
      {:__ENV__, _meta, _} -> "__ENV__"
      {:__DIR__, _meta, _} -> "__DIR__"
      {:__CALLER__, _meta, _} -> "__CALLER__"
      atom when is_atom(atom) -> Atom.to_string(atom)
      {atom, _, _} when is_atom(atom) -> Atom.to_string(atom)
      other -> inspect(other)
    end)
    |> then(fn resolved ->
      # If __MODULE__ was first, it already contains dots (e.g. "Giulia.Core.Foo"),
      # so we join carefully to avoid "Giulia.Core.Foo.Bar" becoming malformed.
      case resolved do
        [mod_string | rest] when is_binary(mod_string) and rest != [] ->
          mod_string <> "." <> Enum.join(rest, ".")
        [mod_string] when is_binary(mod_string) ->
          mod_string
        _ ->
          Enum.join(resolved, ".")
      end
    end)
  end

  # ============================================================================
  # Pass 7: Protocol-dispatch edges
  # ============================================================================

  # For each module declaring `impl_for: ProtoName`, add an edge from
  # `ProtoName` to every function vertex belonging to the impl module,
  # labeled `{:calls, :protocol_impl}`. This makes protocol-dispatched
  # functions reachable in graph traversal — dead_code, change_risk,
  # unprotected_hubs and friends all benefit without per-detector filter
  # logic (Option B in `feedback_dispatch_edge_synthesis.md`).
  #
  # Only emits edges when the protocol vertex already exists in the
  # graph. A project implementing `Jason.Encoder` without Jason in its
  # dependency scope would otherwise spawn orphan vertices.
  defp add_protocol_dispatch_edges(graph, ast_data) do
    impls =
      ast_data
      |> Enum.flat_map(fn {_path, data} ->
        Enum.filter(data[:modules] || [], fn m ->
          is_binary(Map.get(m, :impl_for)) and is_binary(Map.get(m, :name))
        end)
      end)

    Enum.reduce(impls, graph, fn impl_mod, g ->
      proto = impl_mod.impl_for
      impl_name = impl_mod.name

      g = ensure_protocol_vertex(g, proto)

      impl_name
      |> function_vertices_of(g)
      |> Enum.reduce(g, fn fn_vertex, g2 ->
        if Graph.has_vertex?(g2, proto) and
             not has_dispatch_edge?(g2, proto, fn_vertex) do
          Graph.add_edge(g2, proto, fn_vertex, label: {:calls, :protocol_impl})
        else
          g2
        end
      end)
    end)
  end

  # A defimpl without a corresponding defprotocol in scope still deserves
  # the dispatch edge — synthesize a module vertex so the edge has a
  # valid endpoint. This is a synthetic vertex, not an extraction claim.
  defp ensure_protocol_vertex(graph, proto_name) do
    if Graph.has_vertex?(graph, proto_name) do
      graph
    else
      Graph.add_vertex(graph, proto_name, :module)
    end
  end

  defp function_vertices_of(module_name, graph) do
    prefix = module_name <> "."

    graph
    |> Graph.vertices()
    |> Enum.filter(fn v ->
      is_binary(v) and String.starts_with?(v, prefix) and
        :function in Graph.vertex_labels(graph, v)
    end)
  end

  defp has_dispatch_edge?(graph, from, to) do
    graph
    |> Graph.out_edges(from)
    |> Enum.any?(fn edge ->
      edge.v2 == to and match?({:calls, :protocol_impl}, edge.label)
    end)
  end

  # ============================================================================
  # Pass 8: Behaviour-dispatch edges
  # ============================================================================

  # Iterate each module's `imports` for `use X` / `@behaviour X` where X
  # is a known framework behaviour. For each declared callback whose
  # `{name, arity}` matches a function the module defines, emit an
  # edge from the behaviour module to the implementer function. Same
  # architectural role as Pass 7 (`add_protocol_dispatch_edges`) — makes
  # runtime-dispatched callbacks reachable in graph traversal so
  # downstream analyses don't need their own behaviour-awareness logic.
  defp add_behaviour_dispatch_edges(graph, ast_data) do
    Enum.reduce(ast_data, graph, fn {_path, data}, g ->
      modules = data[:modules] || []
      imports = data[:imports] || []
      functions = data[:functions] || []

      declared = Giulia.Knowledge.Behaviours.declared_known_behaviours(imports)

      if declared == [] do
        g
      else
        # "First module wins" is acceptable here: mixed-module-in-one-file
        # is rare for behaviour implementations (GenServers, Phoenix
        # LiveViews, Ecto types all conventionally live one-per-file).
        # If observed later, lift this to a module-stack traversal.
        primary_module =
          case modules do
            [%{name: name} | _] -> name
            _ -> nil
          end

        if primary_module do
          Enum.reduce(declared, g, fn behaviour_name, g2 ->
            g2 = ensure_behaviour_vertex(g2, behaviour_name)
            add_edges_for_declared_behaviour(g2, behaviour_name, primary_module, functions)
          end)
        else
          g
        end
      end
    end)
  end

  defp ensure_behaviour_vertex(graph, behaviour_name) do
    if Graph.has_vertex?(graph, behaviour_name) do
      graph
    else
      Graph.add_vertex(graph, behaviour_name, :module)
    end
  end

  defp add_edges_for_declared_behaviour(graph, behaviour_name, module_name, functions) do
    defined = MapSet.new(functions, fn f -> {to_string(f.name), f.arity} end)

    behaviour_name
    |> Giulia.Knowledge.Behaviours.callbacks_for()
    |> Enum.reduce(graph, fn {cb_name, cb_arity}, g ->
      key = {to_string(cb_name), cb_arity}

      if MapSet.member?(defined, key) do
        impl_vertex = "#{module_name}.#{cb_name}/#{cb_arity}"

        if Graph.has_vertex?(g, impl_vertex) and
             not has_behaviour_dispatch_edge?(g, behaviour_name, impl_vertex) do
          Graph.add_edge(g, behaviour_name, impl_vertex, label: {:calls, :behaviour_impl})
        else
          g
        end
      else
        g
      end
    end)
  end

  defp has_behaviour_dispatch_edge?(graph, from, to) do
    graph
    |> Graph.out_edges(from)
    |> Enum.any?(fn edge ->
      edge.v2 == to and match?({:calls, :behaviour_impl}, edge.label)
    end)
  end

  # ============================================================================
  # Pass 9: Phoenix router dispatch edges
  # ============================================================================

  @router_verbs [:get, :post, :put, :patch, :delete, :head, :options]

  # Standard actions `resources/2,3` generates if no `:only`/`:except` opt.
  # Arity 2 (Phoenix controller convention: `def action(conn, params)`).
  @resources_default_actions [:index, :show, :new, :create, :edit, :update, :delete]

  # Walk every file. If it contains router DSL calls, treat the file's
  # first module as the router and synthesize edges from it to each
  # declared controller action. Files with no route calls are a no-op.
  # Detection-by-content (vs detection-via-`use Phoenix.Router`) avoids
  # the common-in-Plausible case where `use PlausibleWeb, :router`
  # expands the router-DSL macro via a project-internal `__using__/1`
  # that the extractor can't follow.
  defp add_router_dispatch_edges(graph, ast_data) do
    Enum.reduce(ast_data, graph, fn {path, data}, g ->
      router_module =
        case data[:modules] do
          [%{name: name} | _] -> name
          _ -> nil
        end

      if router_module do
        alias_map =
          (data[:imports] || [])
          |> Enum.filter(fn imp -> imp.type == :alias end)
          |> Map.new(fn imp ->
            short = imp.module |> String.split(".") |> List.last()
            {short, imp.module}
          end)

        case File.read(path) do
          {:ok, source} ->
            case Sourceror.parse_string(source) do
              {:ok, ast} ->
                routes = extract_router_routes(ast, alias_map)

                if routes == [] do
                  g
                else
                  add_route_edges(g, router_module, routes)
                end

              _ ->
                g
            end

          _ ->
            g
        end
      else
        g
      end
    end)
  end

  # Returns a list of `{controller_module, action_atom, arity}` tuples.
  # Walks with `Macro.traverse/4` to maintain a scope stack so short
  # controller names inside `scope "/path", Namespace do ... end` blocks
  # resolve through the enclosing namespace (Phoenix's router DSL prepends
  # the scope namespace to short-form controller references).
  defp extract_router_routes(ast, alias_map) do
    {_ast, {routes, _stack}} =
      Macro.traverse(
        ast,
        {[], []},
        fn node, {acc, stack} = state ->
          case scope_namespace(node) do
            {:ok, ns} ->
              {node, {acc, [ns | stack]}}

            :skip ->
              case route_call(node, alias_map, List.first(stack)) do
                {:ok, new_routes} -> {node, {new_routes ++ acc, stack}}
                :skip -> {node, state}
              end
          end
        end,
        fn node, {acc, stack} ->
          case scope_namespace(node) do
            {:ok, _} ->
              case stack do
                [_ | rest] -> {node, {acc, rest}}
                [] -> {node, {acc, []}}
              end

            :skip ->
              {node, {acc, stack}}
          end
        end
      )

    routes
  end

  # Recognize Phoenix router `scope/2,3,4` calls and extract the namespace
  # they introduce for short-form controller references inside. Returns
  # `{:ok, namespace_binary}` when a namespace applies, or `:skip`
  # (including for scopes that add no namespace, like `scope "/flags" do`).
  defp scope_namespace({:scope, _meta, args}) when is_list(args) do
    case namespace_from_scope_args(args) do
      nil -> {:ok, nil}
      ns -> {:ok, ns}
    end
  end

  defp scope_namespace(_), do: :skip

  # `scope path, Namespace, do: body` or
  # `scope path, Namespace, opts, do: body` → Namespace wins.
  # `scope path, opts, do: body` or `scope opts, do: body` → check opts[:alias].
  defp namespace_from_scope_args(args) do
    aliased_args = Enum.find(args, fn
      {:__aliases__, _, _} -> true
      _ -> false
    end)

    cond do
      aliased_args != nil ->
        {:__aliases__, _, parts} = aliased_args
        join_parts(parts)

      true ->
        # Look for an :alias opt in any keyword-list arg.
        args
        |> Enum.find_value(fn
          opts when is_list(opts) ->
            case Keyword.get(opts, :alias) do
              {:__aliases__, _, parts} -> join_parts(parts)
              atom when is_atom(atom) and not is_nil(atom) -> Atom.to_string(atom)
              _ -> nil
            end

          _ ->
            nil
        end)
    end
  end

  # Standard HTTP-verb route: `get "/path", ControllerAlias, :action [, opts]`
  defp route_call(
         {verb, _meta,
          [_path, {:__aliases__, _, parts}, action | _rest]},
         alias_map,
         current_scope_ns
       )
       when verb in @router_verbs and is_atom(action) do
    controller = resolve_controller(parts, alias_map, current_scope_ns)
    {:ok, [{controller, to_string(action), 2}]}
  end

  # Same shape but action wrapped in Sourceror's :__block__.
  defp route_call(
         {verb, _meta,
          [_path, {:__aliases__, _, parts}, {:__block__, _, [action]} | _rest]},
         alias_map,
         current_scope_ns
       )
       when verb in @router_verbs and is_atom(action) do
    controller = resolve_controller(parts, alias_map, current_scope_ns)
    {:ok, [{controller, to_string(action), 2}]}
  end

  # `resources "/path", ControllerAlias` → 7 RESTful actions.
  defp route_call(
         {:resources, _meta, [_path, {:__aliases__, _, parts}]},
         alias_map,
         current_scope_ns
       ) do
    controller = resolve_controller(parts, alias_map, current_scope_ns)
    {:ok, Enum.map(@resources_default_actions, fn a -> {controller, to_string(a), 2} end)}
  end

  # `resources "/path", ControllerAlias, opts` → filter by :only/:except.
  defp route_call(
         {:resources, _meta, [_path, {:__aliases__, _, parts}, opts]},
         alias_map,
         current_scope_ns
       )
       when is_list(opts) do
    controller = resolve_controller(parts, alias_map, current_scope_ns)
    actions = resources_actions_from_opts(opts)
    {:ok, Enum.map(actions, fn a -> {controller, to_string(a), 2} end)}
  end

  defp route_call(_node, _alias_map, _scope_ns), do: :skip

  # Controller-name resolution for router DSL:
  # 1. Join the alias parts into a dotted name (e.g. "SSOController").
  # 2. If a scope namespace is active, prepend it ("PlausibleWeb.SSOController").
  # 3. Fall through to the file-level alias map (multi-segment-aware).
  defp resolve_controller(parts, alias_map, current_scope_ns) do
    raw = join_parts(parts)

    with_scope =
      if current_scope_ns in [nil, ""] do
        raw
      else
        "#{current_scope_ns}.#{raw}"
      end

    resolve_alias_prefix(with_scope, alias_map)
  end

  defp resources_actions_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :only) ->
        only = Keyword.get(opts, :only, [])
        if is_list(only), do: only, else: @resources_default_actions

      Keyword.has_key?(opts, :except) ->
        except = Keyword.get(opts, :except, [])
        if is_list(except), do: @resources_default_actions -- except, else: @resources_default_actions

      true ->
        @resources_default_actions
    end
  end

  defp join_parts(parts) do
    parts
    |> Enum.map(&safe_part_to_string/1)
    |> Enum.join(".")
  end

  defp add_route_edges(graph, router_module, routes) do
    graph = ensure_router_vertex(graph, router_module)

    Enum.reduce(routes, graph, fn {controller, action_name, arity}, g ->
      impl_vertex = "#{controller}.#{action_name}/#{arity}"

      if Graph.has_vertex?(g, impl_vertex) and
           not has_router_dispatch_edge?(g, router_module, impl_vertex) do
        Graph.add_edge(g, router_module, impl_vertex, label: {:calls, :router_dispatch})
      else
        g
      end
    end)
  end

  defp ensure_router_vertex(graph, router_name) do
    if Graph.has_vertex?(graph, router_name) do
      graph
    else
      Graph.add_vertex(graph, router_name, :module)
    end
  end

  defp has_router_dispatch_edge?(graph, from, to) do
    graph
    |> Graph.out_edges(from)
    |> Enum.any?(fn edge ->
      edge.v2 == to and match?({:calls, :router_dispatch}, edge.label)
    end)
  end
end
