defmodule Giulia.Intelligence.ArchitectBrief do
  @moduledoc """
  Single-call project briefing for AI assistants.

  Pure functional module (no GenServer). Composes data from existing
  ETS-indexed sources into one structured response — everything a
  Software Architect needs to understand the project topology, health,
  and constraints in a single API call.

  Designed to be fetched at session start so Claude Code (or any AI
  assistant) begins with full situational awareness instead of
  discovering the project shape through incremental queries.

  Each section is independently error-handled — partial failures
  return fallback values rather than crashing the entire brief.
  """

  alias Giulia.Context.Store
  alias Giulia.Knowledge.Store, as: KnowledgeStore

  require Logger

  @brief_version "build_91"

  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(project_path, _opts \\ []) do
    {:ok,
     %{
       brief_version: @brief_version,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
       project: section_project(project_path),
       topology: section_topology(project_path),
       health: section_health(project_path),
       runtime: section_runtime(project_path),
       constitution: section_constitution(project_path)
     }}
  rescue
    e ->
      Logger.warning("ArchitectBrief: build failed: #{Exception.message(e)}")
      {:error, {:brief_failed, Exception.message(e)}}
  end

  # ============================================================================
  # Section: Project (from Context.Store)
  # ============================================================================

  defp section_project(project_path) do
    summary = Store.Formatter.project_summary(project_path)

    # project_summary returns a formatted string — parse the key counts
    parse_summary_string(summary)
  rescue
    _ -> %{files: 0, modules: 0, functions: 0, error: "project_summary unavailable"}
  end

  defp parse_summary_string(summary) when is_binary(summary) do
    extract = fn key ->
      case Regex.run(~r/#{key}:\s*(\d+)/i, summary) do
        [_, n] -> elem(Integer.parse(n), 0)
        _ -> 0
      end
    end

    %{
      files: extract.("Files"),
      modules: extract.("Modules"),
      functions: extract.("Functions"),
      types: extract.("Types"),
      specs: extract.("Specs"),
      structs: extract.("Structs"),
      callbacks: extract.("Callbacks")
    }
  end

  defp parse_summary_string(_), do: %{files: 0, modules: 0, functions: 0}

  # ============================================================================
  # Section: Topology (from Knowledge.Store)
  # ============================================================================

  defp section_topology(project_path) do
    stats = KnowledgeStore.stats(project_path)

    hubs =
      (stats.hubs || [])
      |> Enum.map(fn
        {name, degree} -> %{module: name, degree: degree}
        %{module: _, degree: _} = m -> m
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    cycles =
      safe_call(
        fn ->
          case KnowledgeStore.find_cycles(project_path) do
            {:ok, result} -> result[:cycles] || []
            _ -> []
          end
        end,
        []
      )

    god_modules =
      safe_call(
        fn ->
          case KnowledgeStore.find_god_modules(project_path) do
            {:ok, %{modules: mods}} -> Enum.take(mods, 10)
            _ -> []
          end
        end,
        []
      )

    %{
      vertices: stats.vertices || 0,
      edges: stats.edges || 0,
      components: stats.components || 0,
      hubs: hubs,
      cycles: cycles,
      god_modules: god_modules
    }
  rescue
    _ ->
      %{
        vertices: 0,
        edges: 0,
        components: 0,
        hubs: [],
        cycles: [],
        god_modules: [],
        error: "topology unavailable"
      }
  end

  # ============================================================================
  # Section: Health (from Knowledge.Store heatmap + integrity)
  # ============================================================================

  defp section_health(project_path) do
    heatmap_data =
      safe_call(
        fn ->
          case KnowledgeStore.heatmap(project_path) do
            {:ok, %{modules: modules}} -> modules
            _ -> []
          end
        end,
        []
      )

    # Summarize zones
    zone_counts = Enum.frequencies_by(heatmap_data, fn m -> m[:zone] || m["zone"] end)

    red_zones =
      heatmap_data
      |> Enum.filter(fn m -> (m[:zone] || m["zone"]) == "red" end)
      |> Enum.take(10)
      |> Enum.map(fn m ->
        %{module: m[:module] || m["module"], score: m[:score] || m["score"]}
      end)

    # Unprotected hubs
    unprotected =
      safe_call(
        fn ->
          case KnowledgeStore.find_unprotected_hubs(project_path) do
            {:ok, result} -> result
            _ -> %{count: 0, modules: []}
          end
        end,
        %{count: 0, modules: []}
      )

    # Behaviour integrity
    integrity =
      safe_call(
        fn ->
          case KnowledgeStore.check_all_behaviours(project_path) do
            {:ok, :consistent} ->
              "consistent"

            {:error, fractures} when is_map(fractures) ->
              "fractured (#{map_size(fractures)} behaviours)"

            _ ->
              "unknown"
          end
        end,
        "unknown"
      )

    %{
      heatmap_summary: %{
        red: zone_counts["red"] || 0,
        yellow: zone_counts["yellow"] || 0,
        green: zone_counts["green"] || 0
      },
      red_zones: red_zones,
      unprotected_hubs: %{
        count: unprotected[:count] || unprotected["count"] || 0,
        modules: Enum.take(unprotected[:modules] || unprotected["modules"] || [], 10)
      },
      integrity: integrity
    }
  rescue
    _ ->
      %{
        heatmap_summary: %{red: 0, yellow: 0, green: 0},
        red_zones: [],
        unprotected_hubs: %{count: 0},
        integrity: "unknown",
        error: "health unavailable"
      }
  end

  # ============================================================================
  # Section: Runtime (from Collector + Inspector, if active)
  # ============================================================================

  defp section_runtime(project_path) do
    if Giulia.Runtime.Collector.active?() do
      pulse =
        safe_call(
          fn ->
            case Giulia.Runtime.Inspector.pulse(:local) do
              {:ok, p} -> p
              _ -> nil
            end
          end,
          nil
        )

      alerts = safe_call(fn -> Giulia.Runtime.Collector.alerts(:local) end, [])

      hot_spots =
        safe_call(
          fn ->
            case Giulia.Runtime.Inspector.hot_spots(:local, project_path) do
              {:ok, spots} -> spots
              _ -> []
            end
          end,
          []
        )

      %{
        available: true,
        pulse: pulse,
        alerts: alerts,
        hot_spots: hot_spots
      }
    else
      %{available: false}
    end
  rescue
    _ -> %{available: false, error: "runtime unavailable"}
  end

  # ============================================================================
  # Section: Constitution (from ProjectContext, if initialized)
  # ============================================================================

  defp section_constitution(project_path) do
    case Giulia.Core.ContextManager.get_context(project_path) do
      {:ok, context_pid} ->
        constitution = Giulia.Core.ProjectContext.get_constitution(context_pid)
        extract_constitution_sections(constitution)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_constitution_sections(nil), do: nil
  defp extract_constitution_sections(""), do: nil

  defp extract_constitution_sections(constitution) when is_binary(constitution) do
    # Extract key sections from GIULIA.md
    tech_stack =
      extract_section(constitution, "Tech Stack") ||
        extract_section(constitution, "Technology")

    taboos =
      extract_section(constitution, "Taboos") ||
        extract_section(constitution, "Never Do")

    %{
      present: true,
      tech_stack: tech_stack,
      taboos: taboos,
      size_bytes: byte_size(constitution)
    }
  end

  defp extract_constitution_sections(_), do: nil

  defp extract_section(text, heading) do
    case Regex.run(~r/##\s*#{Regex.escape(heading)}[^\n]*\n((?:(?!^##\s).)*)/ms, text) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
