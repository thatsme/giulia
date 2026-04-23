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
    graph
    |> promote_function_edges_to_module(all_modules)
    |> add_defdelegate_edges(ast_data, all_modules)
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
    modules = data[:modules] || []
    functions = data[:functions] || []
    module_name = case modules do
      [first | _] -> first.name
      _ -> nil
    end

    if module_name do
      Enum.reduce(functions, graph, fn func, g ->
        vertex_id = "#{module_name}.#{func.name}/#{func.arity}"
        Graph.add_vertex(g, vertex_id, :function)
      end)
    else
      graph
    end
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
        Graph.add_edge(g, caller, callee, label: :calls)
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
      modules = data[:modules] || []
      functions = data[:functions] || []

      case modules do
        [source_mod | _] ->
          caller_module = source_mod.name

          # Build alias map for this file
          alias_map =
            (data[:imports] || [])
            |> Enum.filter(fn imp -> imp.type == :alias end)
            |> Map.new(fn imp ->
              short = imp.module |> String.split(".") |> List.last()
              {short, imp.module}
            end)

          # Read and parse source
          source = case File.read(path) do
            {:ok, content} -> content
            _ -> ""
          end

          case Sourceror.parse_string(source) do
            {:ok, ast} ->
              extract_calls_per_function(g, ast, caller_module, functions, alias_map, all_modules)
            _ ->
              g
          end

        _ ->
          g
      end
    end)
  end

  # Single-pass: walk the entire AST, find def/defp nodes, extract calls from their body.
  # This avoids relying on get_function_range (whose line-range detection is fragile with Sourceror).
  defp extract_calls_per_function(graph, ast, caller_module, _functions, alias_map, all_modules) do
    # Walk the AST to find all def/defp nodes and their bodies
    {_ast, func_call_map} =
      Macro.prewalk(ast, %{}, fn
        # Match def/defp function definitions (with args)
        {def_type, _meta, [{func_name, _fn_meta, args}, body]} = node, acc
        when def_type in [:def, :defp] and is_atom(func_name) ->
          arity = if is_list(args), do: length(args), else: 0
          caller_mfa = "#{caller_module}.#{func_name}/#{arity}"
          calls = extract_calls_from_body(body, caller_module, alias_map, all_modules)
          existing = Map.get(acc, caller_mfa, MapSet.new())
          {node, Map.put(acc, caller_mfa, MapSet.union(existing, calls))}

        # Match def/defp with guard clause: def foo(x) when is_integer(x)
        {def_type, _meta, [{:when, _, [{func_name, _fn_meta, args} | _guards]}, body]} = node, acc
        when def_type in [:def, :defp] and is_atom(func_name) ->
          arity = if is_list(args), do: length(args), else: 0
          caller_mfa = "#{caller_module}.#{func_name}/#{arity}"
          calls = extract_calls_from_body(body, caller_module, alias_map, all_modules)
          existing = Map.get(acc, caller_mfa, MapSet.new())
          {node, Map.put(acc, caller_mfa, MapSet.union(existing, calls))}

        node, acc ->
          {node, acc}
      end)

    # Add edges for all discovered caller→callee relationships
    Enum.reduce(func_call_map, graph, fn {caller_mfa, call_targets}, g ->
      if Graph.has_vertex?(g, caller_mfa) do
        Enum.reduce(call_targets, g, fn target_mfa, g2 ->
          if target_mfa != caller_mfa and Graph.has_vertex?(g2, target_mfa) do
            Graph.add_edge(g2, caller_mfa, target_mfa, label: :calls)
          else
            g2
          end
        end)
      else
        g
      end
    end)
  end

  # Walk a function body AST and collect all call targets as MFA strings
  defp extract_calls_from_body(body, caller_module, alias_map, all_modules) do
    {_body, calls} =
      Macro.prewalk(body, MapSet.new(), fn
        # Remote call: Module.func(args) — resolve aliases
        {{:., _, [{:__aliases__, _meta, parts}, func_name]}, _call_meta, args} = node, set
        when is_atom(func_name) and is_list(args) ->
          raw_mod = resolve_module_parts(parts, caller_module)
          mod = Map.get(alias_map, raw_mod, raw_mod)
          if MapSet.member?(all_modules, mod) do
            target_mfa = "#{mod}.#{func_name}/#{length(args)}"
            {node, MapSet.put(set, target_mfa)}
          else
            {node, set}
          end

        # Remote call with atom module: :erlang.func(args)
        {{:., _, [mod_atom, func_name]}, _meta, args} = node, set
        when is_atom(mod_atom) and is_atom(func_name) and is_list(args) ->
          mod = String.replace_leading(Atom.to_string(mod_atom), "Elixir.", "")
          if MapSet.member?(all_modules, mod) do
            target_mfa = "#{mod}.#{func_name}/#{length(args)}"
            {node, MapSet.put(set, target_mfa)}
          else
            {node, set}
          end

        # Local call: func(args) — same module
        {local_name, _meta, args} = node, set
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
          {node, MapSet.put(set, target_mfa)}

        node, set ->
          {node, set}
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
    |> Enum.filter(fn edge -> edge.label == :calls end)
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
        Graph.add_edge(g, caller_mod, callee_mod, label: :calls)
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
end
