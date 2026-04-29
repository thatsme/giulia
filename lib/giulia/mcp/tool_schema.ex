defmodule Giulia.MCP.ToolSchema do
  @moduledoc """
  Maps Giulia REST skills to MCP tool definitions and resolves tool
  invocations to their dispatch handlers.

  Iterates all domain sub-routers, calls `__skills__/0` on each, filters out
  non-MCP-compatible endpoints (HTML pages, SSE streams), and converts each
  skill map to the `%{name, description, input_schema}` format expected by
  `Anubis.Server.Frame.register_tool/3`.

  Tool names are derived from the endpoint path:
    "GET /api/knowledge/stats" → "knowledge_stats"
    "POST /api/runtime/connect" → "runtime_connect"

  ## Dispatch resolution

  `handler_for/1` resolves a tool name to a `{module, function}` MFA in
  `Giulia.MCP.Dispatch.<Category>`. Single source of truth replacing the
  per-prefix `defp dispatch_<cat>` clauses that previously lived in
  `Giulia.MCP.Server`. Unhandled tools (declared via `@skill` but with
  no matching dispatch function) surface via `unhandled_tools/0`, which
  the MCP server logs at boot.
  """

  alias Giulia.MCP.Dispatch

  @category_modules %{
    "knowledge_" => Dispatch.Knowledge,
    "index_" => Dispatch.Index,
    "search_" => Dispatch.Search,
    "runtime_" => Dispatch.Runtime,
    "intelligence_" => Dispatch.Intelligence,
    "transaction_" => Dispatch.Transaction,
    "approval_" => Dispatch.Approval,
    "monitor_" => Dispatch.Monitor,
    "discovery_" => Dispatch.Discovery
  }

  # Tools whose name does NOT split as `<category>_<fun>` because the
  # endpoint path used a top-level segment (`/api/briefing/...`) instead
  # of nesting under the owning category. Map: tool name → MFA.
  @special_prefix_handlers %{
    "briefing_" => Dispatch.Intelligence,
    "brief_" => Dispatch.Intelligence,
    "plan_" => Dispatch.Intelligence
  }

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

  @doc """
  Resolve a tool name to its dispatch MFA, or `:no_handler` if no
  matching `Giulia.MCP.Dispatch.<Category>` function exists.

  The resolver tries the special-prefix table first (handles
  intelligence-family routes whose endpoint paths don't nest under
  `/api/intelligence/...`), then the regular `<category>_<fun>` split.
  In both cases it confirms via `function_exported?/3` that the target
  function actually exists — atoms-from-strings is unsafe, so the
  function-name lookup uses `String.to_existing_atom/1` and treats
  ArgumentError as `:no_handler`.
  """
  @spec handler_for(String.t()) :: {module(), atom()} | :no_handler
  def handler_for(tool_name) when is_binary(tool_name) do
    with :no_match <- match_special_prefix(tool_name),
         :no_match <- match_category_prefix(tool_name) do
      :no_handler
    end
  end

  @doc """
  Return the list of MCP-compatible tool names that have no resolvable
  dispatch handler. Empty list = every declared tool is invocable.
  Used by `MCP.Server` at boot to log the gap before Tier 3 closes it
  permanently with a fail-loud invariant.
  """
  @spec unhandled_tools() :: [String.t()]
  def unhandled_tools do
    all_tools()
    |> Enum.filter(fn tool -> handler_for(tool.name) == :no_handler end)
    |> Enum.map(& &1.name)
  end

  defp match_special_prefix(tool_name) do
    Enum.find_value(@special_prefix_handlers, :no_match, fn {prefix, module} ->
      if String.starts_with?(tool_name, prefix) do
        resolve_function(module, tool_name)
      else
        nil
      end
    end)
  end

  defp match_category_prefix(tool_name) do
    Enum.find_value(@category_modules, :no_match, fn {prefix, module} ->
      if String.starts_with?(tool_name, prefix) do
        sub = String.replace_prefix(tool_name, prefix, "")
        resolve_function(module, sub)
      else
        nil
      end
    end)
  end

  defp resolve_function(module, fun_str) do
    fun_atom = String.to_existing_atom(fun_str)

    # Code.ensure_loaded?/1 forces the BEAM to load the module before
    # the function-exported check — without it, `function_exported?/3`
    # returns false for any module that hasn't been referenced yet
    # (cold-start, isolated test cases).
    if Code.ensure_loaded?(module) and function_exported?(module, fun_atom, 1) do
      {module, fun_atom}
    else
      :no_match
    end
  rescue
    ArgumentError -> :no_match
  end

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
