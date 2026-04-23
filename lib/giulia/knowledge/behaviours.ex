defmodule Giulia.Knowledge.Behaviours do
  @moduledoc """
  Behaviour integrity checking for the Knowledge Graph.

  Validates that behaviour implementers provide all required callbacks,
  accounting for macro-injected functions and optional callbacks.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

  alias Giulia.Knowledge.MacroMap

  # ============================================================================
  # Known external behaviours
  # ============================================================================
  #
  # Static map of stdlib / ecosystem behaviours to their callback
  # signatures. Keyed by the string module name as it appears in
  # `use SomeModule` or `@behaviour SomeModule` declarations. Covers
  # the frameworks that account for the bulk of real-world Elixir
  # dispatch — dead_code and future graph-traversal analyses use this
  # to avoid flagging callback functions as dead.
  #
  # v1 approach (inline static map): simplest, ships immediately,
  # adequate for the behaviours implemented by >95% of Elixir projects.
  # Maintenance liability acknowledged — callback sets evolve as
  # frameworks change. TODO for future slice: compile-time introspection
  # against loadable behaviour modules so the map becomes derivative,
  # not authoritative.
  @known_behaviour_callbacks %{
    "GenServer" => [
      init: 1, handle_call: 3, handle_cast: 2, handle_info: 2,
      handle_continue: 2, terminate: 2, code_change: 3, format_status: 1, format_status: 2
    ],
    "Supervisor" => [init: 1],
    "DynamicSupervisor" => [init: 1],
    "Application" => [start: 2, stop: 1, config_change: 3, prep_stop: 1, start_phase: 3],
    "Mix.Task" => [run: 1],
    "Mix.Task.Compiler" => [run: 1, manifests: 0, clean: 0],
    "Mix.Project" => [project: 0, application: 0, cli: 0, config: 0, aliases: 0],
    "PromEx.Plugin" => [
      event_metrics: 1, polling_metrics: 1, manual_metrics: 1,
      execute_cache_metrics: 1, execute_write_buffer_metrics: 1
    ],
    "Ecto.Type" => [type: 0, cast: 1, load: 1, dump: 1, equal?: 2, embed_as: 1],
    "Ecto.ParameterizedType" => [
      type: 1, init: 1, cast: 2, load: 3, dump: 2, equal?: 3, embed_as: 1
    ],
    "Plug" => [init: 1, call: 2],
    "Plug.ErrorHandler" => [handle_errors: 2],
    "Phoenix.Controller" => [action: 2, init: 1, call: 2],
    "Phoenix.LiveView" => [
      mount: 3, render: 1, handle_params: 3, handle_event: 3, handle_info: 2,
      handle_call: 3, handle_cast: 2, terminate: 2, handle_async: 3
    ],
    "Phoenix.LiveComponent" => [mount: 1, update: 2, render: 1, handle_event: 3],
    "Phoenix.Endpoint" => [init: 1, call: 2],
    "Phoenix.Param" => [to_param: 1],
    "Phoenix.HTML.Safe" => [to_iodata: 1],
    "Oban.Worker" => [perform: 1, backoff: 1, timeout: 1, new: 2],
    "Bamboo.Adapter" => [deliver: 2, handle_config: 1, supports_attachments?: 0],
    "Jason.Encoder" => [encode: 2]
  }

  @doc """
  List of behaviour module names recognized by the indexer.
  """
  @spec known_behaviours() :: [String.t()]
  def known_behaviours, do: Map.keys(@known_behaviour_callbacks)

  @doc """
  Callback `{name, arity}` pairs for a known behaviour module name,
  or `[]` if the behaviour is unknown.
  """
  @spec callbacks_for(String.t()) :: [{atom(), non_neg_integer()}]
  def callbacks_for(behaviour_name) do
    Map.get(@known_behaviour_callbacks, behaviour_name, [])
  end

  # ============================================================================
  # Behaviour Integrity Check
  # ============================================================================

  @spec behaviour_integrity(Graph.t(), String.t(), String.t()) ::
          {:ok, :consistent} | {:error, :not_found} | {:error, [map()]}
  def behaviour_integrity(graph, behaviour, project_path) do
    if Graph.has_vertex?(graph, behaviour) do
      # Get declared callbacks from ETS
      callbacks = Giulia.Context.Store.Query.list_callbacks(project_path, behaviour)

      if callbacks == [] do
        # Not a behaviour (no callbacks declared)
        {:ok, :consistent}
      else
        callback_set =
          MapSet.new(Enum.map(callbacks, fn cb ->
            {to_string(cb.function), cb.arity}
          end))

        # Split optional vs required callbacks
        optional_set =
          callbacks
          |> Enum.filter(fn cb -> Map.get(cb, :optional, false) == true end)
          |> Enum.map(fn cb -> {to_string(cb.function), cb.arity} end)
          |> MapSet.new()

        required_set = MapSet.difference(callback_set, optional_set)

        # Get implementers: modules with :implements edge pointing TO this behaviour
        implementers =
          Graph.in_edges(graph, behaviour)
          |> Enum.filter(fn edge -> edge.label == :implements end)
          |> Enum.map(fn edge -> edge.v1 end)
          |> Enum.uniq()

        # Check each implementer
        fractures =
          Enum.map(implementers, fn impl_mod ->
            # Get public functions of the implementer
            impl_functions =
              Giulia.Context.Store.Query.list_functions(project_path, impl_mod)
              |> Enum.filter(fn f -> f.type in [:def, :defmacro, :defdelegate, :defguard] end)
              |> Enum.map(fn f -> {to_string(f.name), f.arity} end)
              |> MapSet.new()

            # Get use directives for this implementer and compute macro-injected functions
            use_directives = get_use_directives(project_path, impl_mod)
            macro_injected =
              use_directives
              |> Enum.flat_map(&MacroMap.injected_functions/1)
              |> MapSet.new()

            # Union: explicitly defined + macro-injected
            all_provided = MapSet.union(impl_functions, macro_injected)

            # Find required callbacks truly missing (not defined AND not injected)
            truly_missing =
              required_set
              |> MapSet.difference(all_provided)
              |> MapSet.to_list()

            # Track which callbacks are covered by macros (for enriched output)
            macro_covered =
              callback_set
              |> MapSet.difference(impl_functions)
              |> MapSet.intersection(macro_injected)
              |> MapSet.to_list()

            # Track optional callbacks that are omitted (legal, not fractures)
            optional_missing =
              optional_set
              |> MapSet.difference(all_provided)
              |> MapSet.to_list()

            %{
              implementer: impl_mod,
              missing: truly_missing,
              injected: macro_covered,
              optional_omitted: optional_missing,
              heuristic_injected: []
            }
          end)

        # Post-processing: detect macro ghosts (100% miss heuristic)
        fractures = detect_macro_ghosts(fractures, implementers, project_path)

        # Only report fractures where required callbacks are genuinely missing
        real_fractures = Enum.filter(fractures, fn f -> f.missing != [] end)

        if real_fractures == [] do
          {:ok, :consistent}
        else
          {:error, real_fractures}
        end
      end
    else
      {:error, :not_found}
    end
  end

  @spec all_behaviours(Graph.t(), String.t()) :: {:ok, :consistent} | {:error, map()}
  def all_behaviours(graph, project_path) do
    # Find behaviour modules from ETS (modules that declare @callback).
    behaviour_modules =
      Giulia.Context.Store.Query.list_callbacks(project_path, nil)
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.filter(&Graph.has_vertex?(graph, &1))

    # Check each behaviour
    all_fractures =
      Enum.reduce(behaviour_modules, %{}, fn behaviour, acc ->
        case behaviour_integrity(graph, behaviour, project_path) do
          {:error, fractures} when is_list(fractures) ->
            Map.put(acc, behaviour, fractures)

          _ ->
            acc
        end
      end)

    if map_size(all_fractures) == 0 do
      {:ok, :consistent}
    else
      {:error, all_fractures}
    end
  end

  # ============================================================================
  # Public helper (used by Metrics.dead_code)
  # ============================================================================

  @doc """
  Collect behaviour callback signatures per implementer module.

  Returns a MapSet of `{implementer_module, callback_name, callback_arity}` tuples.
  Used by dead code detection to exclude behaviour callbacks from dead code reports.
  """
  @spec collect_behaviour_callbacks(Graph.t(), String.t()) :: MapSet.t()
  def collect_behaviour_callbacks(graph, project_path) do
    # Source 1: in-tree behaviours — modules declaring @callback that
    # have an :implements edge from an implementer. This has always
    # worked; `Plausible.Imported.Importer`'s callbacks appear here.
    in_tree =
      Graph.edges(graph)
      |> Enum.filter(fn edge -> edge.label == :implements end)
      |> Enum.reduce(MapSet.new(), fn edge, acc ->
        implementer = edge.v1
        behaviour = edge.v2

        callbacks = Giulia.Context.Store.Query.list_callbacks(project_path, behaviour)

        Enum.reduce(callbacks, acc, fn cb, set ->
          MapSet.put(set, {implementer, to_string(cb.function), cb.arity})
        end)
      end)

    # Source 2: external behaviours from `@known_behaviour_callbacks`.
    # The behaviour module (GenServer, Mix.Task, Ecto.Type, etc.) is
    # not in the project graph, so there's no :implements edge to walk.
    # Instead, iterate module_info entries, find declarations of known
    # behaviours via `use X` or `@behaviour X` in imports, and emit
    # exemption tuples for each callback in the known map.
    all_asts = Giulia.Context.Store.all_asts(project_path)

    external =
      Enum.reduce(all_asts, MapSet.new(), fn {_path, data}, acc ->
        modules = data[:modules] || []
        imports = data[:imports] || []

        declared = declared_known_behaviours(imports)

        Enum.reduce(modules, acc, fn mod, acc2 ->
          Enum.reduce(declared, acc2, fn behaviour_name, acc3 ->
            Enum.reduce(callbacks_for(behaviour_name), acc3, fn {cb_name, cb_arity}, set ->
              MapSet.put(set, {mod.name, to_string(cb_name), cb_arity})
            end)
          end)
        end)
      end)

    MapSet.union(in_tree, external)
  end

  @doc false
  # Returns the list of known-behaviour module names declared by a
  # module's imports. Handles both `use X` and `@behaviour X`; the
  # current extractor conflates them under `type: :use` so we look at
  # that type and filter against the known-behaviours table. Either
  # form is treated as "this module commits to implementing X's
  # callbacks" — which is true at the Elixir level too (use typically
  # injects @behaviour).
  @spec declared_known_behaviours([map()]) :: [String.t()]
  def declared_known_behaviours(imports) do
    imports
    |> Enum.filter(fn imp ->
      imp.type in [:use, :behaviour] and Map.has_key?(@known_behaviour_callbacks, imp.module)
    end)
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  # --- Private helpers ---

  # Heuristic: if a callback is "missing" from 100% of implementers,
  # AND all those implementers `use` the behaviour module (or a shared module),
  # it's likely injected by a macro. Reclassify from missing → heuristic_injected.
  defp detect_macro_ghosts(fractures, implementers, project_path) when length(implementers) >= 2 do
    # Group all missing callbacks across implementers
    all_missing =
      fractures
      |> Enum.flat_map(fn f -> Enum.map(f.missing, fn cb -> {cb, f.implementer} end) end)
      |> Enum.group_by(fn {cb, _impl} -> cb end, fn {_cb, impl} -> impl end)

    impl_count = length(implementers)

    # Callbacks missing from ALL implementers = ghost candidates
    ghost_candidates =
      all_missing
      |> Enum.filter(fn {_cb, impls} -> length(Enum.uniq(impls)) == impl_count end)
      |> Enum.map(fn {cb, _impls} -> cb end)
      |> MapSet.new()

    if MapSet.size(ghost_candidates) == 0 do
      fractures
    else
      # Verify all implementers share a common `use` directive
      use_sets =
        Enum.map(implementers, fn impl ->
          MapSet.new(get_use_directives(project_path, impl))
        end)

      common_uses =
        case use_sets do
          [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
          [] -> MapSet.new()
        end

      if MapSet.size(common_uses) > 0 do
        # Reclassify ghost candidates
        Enum.map(fractures, fn f ->
          {ghosts, real_missing} =
            Enum.split_with(f.missing, fn cb -> MapSet.member?(ghost_candidates, cb) end)

          %{f | missing: real_missing, heuristic_injected: f.heuristic_injected ++ ghosts}
        end)
      else
        fractures
      end
    end
  end

  defp detect_macro_ghosts(fractures, _implementers, _project_path), do: fractures

  # Get use directives for a module from ETS
  defp get_use_directives(project_path, module_name) do
    case Giulia.Context.Store.Query.find_module(project_path, module_name) do
      {:ok, %{ast_data: ast_data}} ->
        (ast_data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :use end)
        |> Enum.map(fn imp -> imp.module end)

      _ ->
        []
    end
  end
end
