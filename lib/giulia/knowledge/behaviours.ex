defmodule Giulia.Knowledge.Behaviours do
  @moduledoc """
  Behaviour integrity checking for the Knowledge Graph.

  Validates that behaviour implementers provide all required callbacks,
  accounting for macro-injected functions and optional callbacks.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

  alias Giulia.Knowledge.MacroMap

  # ============================================================================
  # Behaviour Integrity Check
  # ============================================================================

  def behaviour_integrity(graph, behaviour, project_path) do
    if not Graph.has_vertex?(graph, behaviour) do
      {:error, :not_found}
    else
      # Get declared callbacks from ETS
      callbacks = Giulia.Context.Store.list_callbacks(project_path, behaviour)

      if callbacks == [] do
        # Not a behaviour (no callbacks declared)
        {:ok, :consistent}
      else
        callback_set =
          Enum.map(callbacks, fn cb ->
            {to_string(cb.function), cb.arity}
          end)
          |> MapSet.new()

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
              Giulia.Context.Store.list_functions(project_path, impl_mod)
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
    end
  end

  def all_behaviours(graph, project_path) do
    # Find behaviour modules from ETS (modules that declare @callback).
    behaviour_modules =
      Giulia.Context.Store.list_callbacks(project_path)
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
  def collect_behaviour_callbacks(graph, project_path) do
    Graph.edges(graph)
    |> Enum.filter(fn edge -> edge.label == :implements end)
    |> Enum.reduce(MapSet.new(), fn edge, acc ->
      implementer = edge.v1
      behaviour = edge.v2

      callbacks = Giulia.Context.Store.list_callbacks(project_path, behaviour)

      Enum.reduce(callbacks, acc, fn cb, set ->
        MapSet.put(set, {implementer, to_string(cb.function), cb.arity})
      end)
    end)
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
          get_use_directives(project_path, impl) |> MapSet.new()
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
    case Giulia.Context.Store.find_module(project_path, module_name) do
      {:ok, %{ast_data: ast_data}} ->
        (ast_data[:imports] || [])
        |> Enum.filter(fn imp -> imp.type == :use end)
        |> Enum.map(fn imp -> imp.module end)

      _ ->
        []
    end
  end
end
