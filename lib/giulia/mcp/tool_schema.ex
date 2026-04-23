defmodule Giulia.MCP.ToolSchema do
  @moduledoc """
  Maps Giulia REST skills to MCP tool definitions.

  Iterates all domain sub-routers, calls `__skills__/0` on each, filters out
  non-MCP-compatible endpoints (HTML pages, SSE streams), and converts each
  skill map to the `%{name, description, input_schema}` format expected by
  `Anubis.Server.Frame.register_tool/3`.

  Tool names are derived from the endpoint path:
    "GET /api/knowledge/stats" → "knowledge_stats"
    "POST /api/runtime/connect" → "runtime_connect"
  """

  @routers [
    Giulia.Daemon.Routers.Discovery,
    Giulia.Daemon.Routers.Approval,
    Giulia.Daemon.Routers.Transaction,
    Giulia.Daemon.Routers.Index,
    Giulia.Daemon.Routers.Search,
    Giulia.Daemon.Routers.Intelligence,
    Giulia.Daemon.Routers.Runtime,
    Giulia.Daemon.Routers.Knowledge,
    Giulia.Daemon.Routers.Monitor
  ]

  # Explicit name overrides for collision or clarity
  @name_overrides %{
    "POST /api/approval/:approval_id" => "approval_respond",
    "GET /api/approval/:approval_id" => "approval_get_pending",
    "GET /api/search" => "search_text"
  }

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @doc "Build MCP tool definitions for all compatible skills."
  @spec all_tools() :: [tool_def()]
  def all_tools do
    @routers
    |> Enum.flat_map(& &1.__skills__())
    |> Enum.filter(&mcp_compatible?/1)
    |> Enum.map(&skill_to_tool/1)
  end

  @doc "Return the list of router modules used for tool discovery."
  @spec routers() :: [module()]
  def routers, do: @routers

  # --- Conversion ---

  defp skill_to_tool(skill) do
    %{
      name: tool_name(skill),
      description: skill.intent,
      input_schema: build_input_schema(skill)
    }
  end

  defp tool_name(skill) do
    case Map.get(@name_overrides, skill.endpoint) do
      nil -> endpoint_to_tool_name(skill.endpoint)
      override -> override
    end
  end

  defp endpoint_to_tool_name(endpoint_str) do
    endpoint_str
    |> String.split(" ", parts: 2)
    |> List.last()
    |> String.trim_leading("/api/")
    |> String.replace(~r/:(\w+)/, "by_\\1")
    |> String.replace("/", "_")
  end

  # --- Input schema ---

  defp build_input_schema(skill) do
    skill.params
    |> Enum.map(fn {name, requirement} ->
      desc = param_description(name, requirement)

      type =
        if required?(requirement),
          do: {:required, :string, [description: desc]},
          else: {:string, [description: desc]}

      {to_string(name), type}
    end)
    |> Map.new()
  end

  defp required?(:required), do: true

  defp required?(desc) when is_binary(desc) do
    desc |> String.downcase() |> String.starts_with?("required")
  end

  defp required?(_), do: false

  defp param_description(name, :required), do: "#{name} (required)"
  defp param_description(name, :optional), do: "#{name} (optional)"
  defp param_description(_name, desc) when is_binary(desc), do: desc
  defp param_description(name, _), do: to_string(name)

  # --- Filtering ---

  @doc false
  # Public for filter-accountability testing. Not part of the module's
  # API surface. A skill is MCP-compatible unless its return type is
  # HTML/SSE/stream or its endpoint ends in `/stream`. Kept as a pure
  # function of the skill map so the test suite can exercise it with
  # hand-crafted fixtures rather than the live routers' @skill data.
  @spec mcp_compatible?(map()) :: boolean()
  def mcp_compatible?(skill) do
    returns = String.downcase(skill.returns)
    endpoint = String.downcase(skill.endpoint)

    not String.contains?(returns, "html") and
      not String.contains?(returns, "server-sent events") and
      not String.contains?(returns, "sse stream") and
      not ends_with_stream?(endpoint)
  end

  # Match the path suffix `/stream` anchored at the end. Using
  # String.contains?(endpoint, "/stream") was over-eager — it would
  # also match paths like `/api/foo/stream_stats` or anything with
  # the substring. The intent is terminal SSE endpoints only.
  defp ends_with_stream?(endpoint) do
    String.ends_with?(endpoint, "/stream")
  end
end
