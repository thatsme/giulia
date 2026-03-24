defmodule Giulia.Knowledge.Insights.Impact do
  @moduledoc """
  Pre-impact risk analysis for rename/remove/refactor operations.

  Analyzes the Knowledge Graph to compute blast radius, affected callers,
  risk scores, hub warnings, and staged rollout phases before any
  destructive refactoring action.

  Extracted from `Knowledge.Insights` (Build 128).
  """

  alias Giulia.Knowledge.Topology

  # ============================================================================
  # Public API
  # ============================================================================

  @spec pre_impact_check(Graph.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def pre_impact_check(graph, project_path, params) do
    action = params["action"]
    module = params["module"]
    target = params["target"]
    new_name = params["new_name"]

    case action do
      "rename_function" ->
        check_rename_function(graph, project_path, module, target, new_name)

      "remove_function" ->
        check_remove_function(graph, project_path, module, target)

      "rename_module" ->
        check_rename_module(graph, project_path, module, new_name)

      _ ->
        {:error, {:unknown_action, action}}
    end
  end

  @doc """
  Enrich an MFA vertex string with file and line metadata from ETS.

  Used by both impact analysis and logic_flow tracing.
  """
  @spec enrich_mfa_vertex(String.t(), String.t()) :: map()
  def enrich_mfa_vertex(mfa, project_path) do
    case parse_mfa_vertex(mfa) do
      {:ok, module, function, arity} ->
        {file, line} =
          case Giulia.Context.Store.Query.find_module(project_path, module) do
            {:ok, %{file: file, ast_data: ast_data}} ->
              func_line =
                (ast_data[:functions] || [])
                |> Enum.find(fn f ->
                  to_string(f.name) == function and f.arity == arity
                end)
                |> case do
                  nil -> nil
                  f -> f.line
                end

              {file, func_line}

            _ ->
              {nil, nil}
          end

        %{mfa: mfa, module: module, function: function, arity: arity, file: file, line: line}

      :error ->
        %{mfa: mfa, module: mfa, function: nil, arity: nil, file: nil, line: nil}
    end
  end

  # ============================================================================
  # Action Checks
  # ============================================================================

  defp check_rename_function(graph, project_path, module, target, new_name) do
    case parse_func_target(target) do
      {:ok, func_name, arity} ->
        mfa = "#{module}.#{func_name}/#{arity}"

        if not Graph.has_vertex?(graph, mfa) do
          {:error, {:not_found, mfa}}
        else
          callers =
            Graph.in_neighbors(graph, mfa)
            |> Enum.filter(fn v -> String.contains?(v, "/") end)

          affected =
            Enum.map(callers, fn caller_mfa ->
              enrich_mfa_vertex(caller_mfa, project_path)
            end)

          affected_modules =
            affected
            |> Enum.map(& &1.module)
            |> Enum.uniq()

          new_mfa = "#{module}.#{new_name}/#{arity}"

          risk = impact_risk(length(callers), length(affected_modules), graph, affected_modules)
          phases = build_phases(module, affected, graph)

          warnings = build_hub_warnings(graph, affected_modules)

          {:ok,
           %{
             action: "rename_function",
             target: mfa,
             new_name: new_mfa,
             affected_callers: affected,
             affected_count: length(affected),
             affected_modules: length(affected_modules),
             risk_score: risk,
             risk_level: risk_level(risk),
             phases: phases,
             warnings: warnings
           }}
        end

      :error ->
        {:error, {:invalid_target, target}}
    end
  end

  defp check_remove_function(graph, project_path, module, target) do
    case parse_func_target(target) do
      {:ok, func_name, arity} ->
        mfa = "#{module}.#{func_name}/#{arity}"

        if not Graph.has_vertex?(graph, mfa) do
          {:error, {:not_found, mfa}}
        else
          callers =
            Graph.in_neighbors(graph, mfa)
            |> Enum.filter(fn v -> String.contains?(v, "/") end)

          callees =
            Graph.out_neighbors(graph, mfa)
            |> Enum.filter(fn v -> String.contains?(v, "/") end)

          affected =
            Enum.map(callers, fn caller_mfa ->
              enrich_mfa_vertex(caller_mfa, project_path)
            end)

          affected_modules =
            affected
            |> Enum.map(& &1.module)
            |> Enum.uniq()

          risk = impact_risk(length(callers), length(affected_modules), graph, affected_modules)
          phases = build_phases(module, affected, graph)

          warnings =
            build_hub_warnings(graph, affected_modules) ++
              if length(callers) > 0 do
                ["BREAKING: #{length(callers)} callers will break if #{mfa} is removed"]
              else
                []
              end

          orphaned =
            Enum.filter(callees, fn callee ->
              callers_of_callee = Graph.in_neighbors(graph, callee)
              callers_of_callee == [mfa] or callers_of_callee == []
            end)

          {:ok,
           %{
             action: "remove_function",
             target: mfa,
             affected_callers: affected,
             affected_count: length(affected),
             affected_modules: length(affected_modules),
             potentially_orphaned: orphaned,
             risk_score: risk,
             risk_level: risk_level(risk),
             phases: phases,
             warnings: warnings
           }}
        end

      :error ->
        {:error, {:invalid_target, target}}
    end
  end

  defp check_rename_module(graph, project_path, module, new_name) do
    if not Graph.has_vertex?(graph, module) do
      {:error, {:not_found, module}}
    else
      case Topology.dependents(graph, module) do
        {:ok, deps} ->
          hub_penalty =
            case Topology.centrality(graph, module) do
              {:ok, %{in_degree: in_deg}} when in_deg >= 10 -> in_deg * 3
              {:ok, %{in_degree: in_deg}} -> in_deg
              _ -> 0
            end

          affected =
            Enum.map(deps, fn dep ->
              case Giulia.Context.Store.Query.find_module(project_path, dep) do
                {:ok, %{file: file}} -> %{module: dep, file: file}
                _ -> %{module: dep, file: nil}
              end
            end)

          risk = length(deps) * 5 + hub_penalty

          warnings =
            if hub_penalty > 30,
              do: ["HUB MODULE: #{module} has #{hub_penalty} hub penalty"],
              else: []

          {:ok,
           %{
             action: "rename_module",
             target: module,
             new_name: new_name,
             affected_dependents: affected,
             affected_count: length(affected),
             risk_score: risk,
             risk_level: risk_level(risk),
             warnings: warnings
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Phase algorithm: target first, then leaf callers, then interconnected
  defp build_phases(target_module, affected_callers, graph) do
    phase1 = %{phase: 1, description: "Update target definition", modules: [target_module]}

    caller_modules =
      affected_callers
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == target_module))

    affected_set = MapSet.new(caller_modules)

    {leaves, interconnected} =
      Enum.split_with(caller_modules, fn mod ->
        deps =
          case Graph.out_neighbors(graph, mod) do
            neighbors when is_list(neighbors) -> neighbors
            _ -> []
          end

        not Enum.any?(deps, fn dep -> MapSet.member?(affected_set, dep) and dep != mod end)
      end)

    phases = [phase1]

    phases =
      if leaves != [],
        do:
          phases ++ [%{phase: 2, description: "Update leaf callers", modules: Enum.sort(leaves)}],
        else: phases

    phases =
      if interconnected != [],
        do:
          phases ++
            [
              %{
                phase: 3,
                description: "Update interconnected callers",
                modules: Enum.sort(interconnected)
              }
            ],
        else: phases

    phases
  end

  defp impact_risk(caller_count, module_count, graph, affected_modules) do
    hub_penalty =
      Enum.sum(
        Enum.map(affected_modules, fn mod ->
          case Topology.centrality(graph, mod) do
            {:ok, %{in_degree: in_deg}} when in_deg >= 10 -> 10
            _ -> 0
          end
        end)
      )

    caller_count * 2 + module_count * 5 + hub_penalty
  end

  defp risk_level(score) when score < 20, do: "low"
  defp risk_level(score) when score < 50, do: "medium"
  defp risk_level(_score), do: "high"

  defp build_hub_warnings(graph, affected_modules) do
    Enum.flat_map(affected_modules, fn mod ->
      case Topology.centrality(graph, mod) do
        {:ok, %{in_degree: in_deg}} when in_deg >= 10 ->
          ["HUB CALLER: #{mod} has #{in_deg} dependents"]

        _ ->
          []
      end
    end)
  end

  # Parse "func/arity" or "func_name/2" into {:ok, "func", 2}
  defp parse_func_target(target) do
    case Regex.run(~r/^(.+)\/(\d+)$/, target) do
      [_, func, arity_str] -> {:ok, func, elem(Integer.parse(arity_str), 0)}
      _ -> :error
    end
  end

  # Parse "Giulia.Foo.bar/2" into {:ok, "Giulia.Foo", "bar", 2}
  defp parse_mfa_vertex(mfa) do
    case Regex.run(~r/^(.+)\.([^.]+)\/(\d+)$/, mfa) do
      [_, module, function, arity_str] ->
        {:ok, module, function, elem(Integer.parse(arity_str), 0)}

      _ ->
        :error
    end
  end
end
