defmodule Giulia.MCP.Dispatch.Intelligence do
  @moduledoc """
  MCP dispatch handlers for the `intelligence_*` / `briefing_*` /
  `brief_*` / `plan_*` tool families.

  All four prefix routes funnel into this module — `MCP.Server` preserves
  the original sub-key (e.g. `briefing_preflight`, `brief_architect`)
  when delegating, so the function names here match the MCP tool names
  without the category prefix.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Core.PathMapper
  alias Giulia.Enrichment.Reader
  alias Giulia.Intelligence.{ArchitectBrief, PlanValidator, Preflight, SurgicalBriefing}

  @spec briefing(map()) :: {:ok, term()} | {:error, String.t()}
  def briefing(args) do
    with {:ok, path} <- require_path(args) do
      concept = args["prompt"] || args["q"]

      if concept do
        case SurgicalBriefing.build(path, concept) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, inspect(reason)}
        end
      else
        {:error, "Missing required parameter: prompt (or q)"}
      end
    end
  end

  @spec briefing_preflight(map()) :: {:ok, term()} | {:error, String.t()}
  def briefing_preflight(args) do
    with {:ok, _path_raw} <- require_param(args, "path"),
         {:ok, prompt} <- require_param(args, "prompt") do
      path = PathMapper.resolve_path(args["path"])
      top_k = parse_int(args["top_k"], 5)
      depth = parse_int(args["depth"], 2)

      case Preflight.run(path, prompt, top_k: top_k, depth: depth) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @spec brief_architect(map()) :: {:ok, term()} | {:error, String.t()}
  def brief_architect(args) do
    with {:ok, path} <- require_path(args) do
      case ArchitectBrief.build(path) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @spec plan_validate(map()) :: {:ok, term()} | {:error, String.t()}
  def plan_validate(args) do
    with {:ok, _path_raw} <- require_param(args, "path"),
         {:ok, plan} <- require_param(args, "plan") do
      path = PathMapper.resolve_path(args["path"])

      case PlanValidator.validate(path, plan) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @spec enrichments(map()) :: {:ok, map()} | {:error, String.t()}
  def enrichments(args) do
    with {:ok, path} <- require_path(args) do
      mfa = args["mfa"]
      module = args["module"]

      cond do
        is_binary(mfa) and mfa != "" ->
          {:ok, %{findings: Reader.fetch_for_mfa(path, mfa), target: mfa}}

        is_binary(module) and module != "" ->
          {:ok, %{findings: Reader.fetch_for_module(path, module), target: module}}

        true ->
          {:error, "Provide either :mfa or :module parameter"}
      end
    end
  end

  @spec report_rules(map()) :: {:ok, map()}
  def report_rules(_args) do
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
end
