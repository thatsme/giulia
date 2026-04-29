defmodule Giulia.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server exposing Giulia code intelligence as
  tools and resources.

  Uses the Streamable HTTP transport via anubis_mcp. Clients connect to
  the /mcp endpoint, authenticate with a Bearer token, and can discover
  and invoke Giulia analysis tools through the standard MCP protocol.

  Tool dispatch is fully table-driven via `Giulia.MCP.ToolSchema.handler_for/1`,
  which resolves each tool name to a `{module, function}` MFA in the
  matching `Giulia.MCP.Dispatch.<Category>` module. Adding a new MCP
  tool means: declare an `@skill` in the matching router AND add a
  function in the matching dispatch module — `unhandled_tools/0`
  surfaces the gap at boot.
  """

  use Anubis.Server,
    name: "giulia",
    version: Giulia.MixProject.project()[:version] || "0.0.0",
    capabilities: [:tools, :resources]

  require Logger

  alias Anubis.MCP.Error
  alias Anubis.Server.Response
  alias Giulia.MCP.{ResourceProvider, ToolSchema}

  @tool_timeout 30_000

  @impl true
  def init(client_info, frame) do
    Logger.info("[MCP] Client connected: #{inspect(client_info["name"])}")
    log_unhandled_tools()

    frame =
      frame
      |> register_all_tools()
      |> ResourceProvider.register_templates()

    {:ok, frame}
  end

  @impl true
  def handle_tool_call(name, args, frame) do
    case ToolSchema.handler_for(name) do
      {module, fun} ->
        execute(frame, fn -> apply(module, fun, [args]) end)

      :no_handler ->
        {:error, Error.protocol(:invalid_params, %{message: "Unknown tool: #{name}"}), frame}
    end
  end

  @impl true
  def handle_resource_read(uri, frame) do
    ResourceProvider.read(uri, frame)
  end

  @impl true
  def handle_info(_msg, frame) do
    {:noreply, frame}
  end

  # ============================================================================
  # Internal helpers — protocol-side concerns only (registration, supervised
  # execute/timeout, gap reporting). Argument coercion and per-tool
  # business logic live in `Giulia.MCP.Dispatch.*`.
  # ============================================================================

  defp register_all_tools(frame) do
    ToolSchema.all_tools()
    |> Enum.reduce(frame, fn tool_def, acc ->
      Anubis.Server.Frame.register_tool(acc, tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema
      )
    end)
  end

  defp log_unhandled_tools do
    case ToolSchema.unhandled_tools() do
      [] ->
        :ok

      gaps ->
        Logger.warning(
          "[MCP] #{length(gaps)} declared tool(s) have no dispatch handler — " <>
            "will return invalid_params on call: #{Enum.join(gaps, ", ")}. " <>
            "Add the matching function in Giulia.MCP.Dispatch.<Category> to close the gap."
        )
    end
  end

  defp execute(frame, fun) do
    task = Task.Supervisor.async_nolink(Giulia.TaskSupervisor, fun)

    case Task.yield(task, @tool_timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:reply, Response.tool() |> Response.text(Jason.encode!(result, pretty: true)), frame}

      {:ok, {:error, message}} when is_binary(message) ->
        {:reply, Response.tool() |> Response.error(message), frame}

      {:ok, {:error, reason}} ->
        {:reply, Response.tool() |> Response.error(inspect(reason)), frame}

      nil ->
        {:reply, Response.tool() |> Response.error("Tool execution timed out"), frame}

      {:exit, reason} ->
        {:reply, Response.tool() |> Response.error("Tool crashed: #{inspect(reason)}"), frame}
    end
  rescue
    e ->
      {:reply, Response.tool() |> Response.error("Tool error: #{Exception.message(e)}"), frame}
  end
end
