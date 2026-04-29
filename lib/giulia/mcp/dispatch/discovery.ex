defmodule Giulia.MCP.Dispatch.Discovery do
  @moduledoc """
  MCP dispatch handlers for the `discovery_*` tool family.

  These tools introspect the registered routers and surface skill metadata
  back to clients — the same data MCP itself consumes for `tools/list`.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.MCP.Dispatch.Intelligence
  alias Giulia.MCP.ToolSchema

  @spec skills(map()) :: {:ok, map()}
  def skills(args) do
    skills =
      ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())

    filtered =
      case args["category"] do
        nil -> skills
        cat -> Enum.filter(skills, &(&1.category == cat))
      end

    {:ok, %{skills: filtered, count: length(filtered)}}
  end

  @spec categories(map()) :: {:ok, map()}
  def categories(_args) do
    categories =
      ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, skills} -> %{category: cat, count: length(skills)} end)
      |> Enum.sort_by(& &1.category)

    {:ok, %{categories: categories, total: length(categories)}}
  end

  @spec search(map()) :: {:ok, map()} | {:error, String.t()}
  def search(args) do
    with {:ok, q} <- require_param(args, "q") do
      q_lower = String.downcase(q)

      matches =
        ToolSchema.routers()
        |> Enum.flat_map(& &1.__skills__())
        |> Enum.filter(fn skill -> String.contains?(String.downcase(skill.intent), q_lower) end)

      {:ok, %{skills: matches, count: length(matches), query: q}}
    end
  end

  @spec report_rules(map()) :: {:ok, map()}
  def report_rules(_args), do: Intelligence.report_rules(%{})
end
