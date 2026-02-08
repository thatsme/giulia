defmodule Giulia.Intelligence.SurgicalBriefing do
  @moduledoc """
  Automatic Layer 1+2 pre-processing.

  Runs BEFORE the LLM sees the prompt:
  1. Layer 1 (Bumblebee): SemanticIndex.search → find relevant modules/functions
  2. Layer 2 (Knowledge Graph): Enrich with centrality, dependents, change risk
  3. Output: Formatted "Surgical Briefing" text block injected into the prompt
  """

  alias Giulia.Intelligence.SemanticIndex
  alias Giulia.Knowledge.Store, as: KnowledgeStore

  require Logger

  @relevance_threshold 0.4
  @hub_threshold 3

  @spec build(String.t(), String.t()) :: {:ok, String.t()} | :skip
  def build(prompt, project_path) do
    if SemanticIndex.available?() do
      do_build(prompt, project_path)
    else
      Logger.debug("SurgicalBriefing: Skipped (semantic search unavailable)")
      :skip
    end
  rescue
    e ->
      Logger.warning("SurgicalBriefing: Skipped (error: #{inspect(e)})")
      :skip
  end

  defp do_build(prompt, project_path) do
    case SemanticIndex.search(project_path, prompt, 5) do
      {:ok, %{modules: modules, functions: functions}} when modules != [] ->
        top_score = hd(modules).score

        if top_score >= @relevance_threshold do
          enriched = enrich_modules(modules, project_path)
          briefing = format_briefing(enriched, functions, project_path)
          Logger.info("SurgicalBriefing: Injected briefing with #{length(enriched)} modules")
          {:ok, briefing}
        else
          Logger.debug("SurgicalBriefing: Skipped (below relevance threshold, top=#{top_score})")
          :skip
        end

      {:ok, _} ->
        Logger.debug("SurgicalBriefing: Skipped (no module results)")
        :skip

      {:error, reason} ->
        Logger.debug("SurgicalBriefing: Skipped (search error: #{inspect(reason)})")
        :skip
    end
  end

  defp enrich_modules(modules, project_path) do
    Enum.map(modules, fn mod ->
      module_name = mod.id

      {hub_score, dependents_count} =
        case KnowledgeStore.centrality(project_path, module_name) do
          {:ok, %{in_degree: in_deg, out_degree: out_deg, dependents: deps}} ->
            {%{in_degree: in_deg, out_degree: out_deg}, length(deps)}

          _ ->
            {nil, 0}
        end

      Map.merge(mod, %{
        hub_score: hub_score,
        dependents_count: dependents_count
      })
    end)
  end

  defp format_briefing(modules, functions, _project_path) do
    module_lines =
      modules
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {mod, idx} ->
        file = mod.metadata[:file] || mod.metadata["file"] || "unknown"
        score = Float.round(mod.score, 2)

        hub_line =
          case mod.hub_score do
            %{in_degree: ind, out_degree: outd} ->
              level = if ind >= @hub_threshold, do: "HIGH — approval gate required", else: "normal"
              "\n   - Hub score: #{ind} in / #{outd} out (#{level})"

            nil ->
              ""
          end

        deps_line =
          if mod.dependents_count > 0 do
            "\n   - Dependents: #{mod.dependents_count} modules depend on this"
          else
            ""
          end

        "#{idx}. #{mod.id} (relevance: #{score})" <>
          hub_line <>
          "\n   - File: #{file}" <>
          deps_line
      end)

    function_lines =
      functions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {func, idx} ->
        file = func.metadata[:file] || func.metadata["file"] || "unknown"
        line = func.metadata[:line] || func.metadata["line"] || "?"
        score = Float.round(func.score, 2)
        "#{idx}. #{func.id} (#{score}) — #{file}:#{line}"
      end)

    warning = hub_warning(modules)

    """
    --- SURGICAL BRIEFING (auto-generated) ---

    Relevant modules for your request:
    #{module_lines}

    Key functions:
    #{function_lines}
    #{warning}\
    --- END BRIEFING ---\
    """
  end

  defp hub_warning(modules) do
    hubs =
      Enum.filter(modules, fn mod ->
        case mod.hub_score do
          %{in_degree: ind} when ind >= @hub_threshold -> true
          _ -> false
        end
      end)

    case hubs do
      [] ->
        ""

      hubs ->
        names = Enum.map_join(hubs, ", ", & &1.id)

        "\n⚠ High-centrality modules detected. Changes to #{names} require staging mode.\n"
    end
  end
end
