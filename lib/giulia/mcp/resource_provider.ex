defmodule Giulia.MCP.ResourceProvider do
  @moduledoc """
  Maps Giulia data to MCP resource templates.

  Registers URI templates for browsing Giulia's data stores (projects, modules,
  graph stats, skills, status) via the `giulia://` URI scheme. Resolves
  `resources/read` requests to the appropriate context module.

  Path parameters in URIs are URI-decoded and run through
  `Giulia.Core.PathMapper.resolve_path/1` for host↔container translation.
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Anubis.MCP.Error

  @type read_result ::
          {:reply, Response.t(), Frame.t()}
          | {:error, Error.t(), Frame.t()}

  @doc "Register all resource templates on the frame."
  @spec register_templates(Frame.t()) :: Frame.t()
  def register_templates(frame) do
    frame
    |> Frame.register_resource_template("giulia://projects/{path}",
      name: "projects",
      title: "Projects",
      description: "Project summary and index stats. Use 'list' as path for all projects.",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("giulia://modules/{path}",
      name: "modules",
      title: "Indexed Modules",
      description: "List indexed modules for a project path",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("giulia://graph/{path}",
      name: "graph",
      title: "Knowledge Graph",
      description: "Knowledge graph statistics for a project path",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("giulia://skills/{category}",
      name: "skills",
      title: "API Skills",
      description: "Available API skills. Use 'list' for all, or a category name.",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("giulia://status",
      name: "status",
      title: "Daemon Status",
      description: "Giulia daemon status (node, version, active projects)",
      mime_type: "application/json"
    )
  end

  @doc "Resolve a resource URI to content."
  @spec read(String.t(), Frame.t()) :: read_result()
  def read("giulia://projects/" <> path_encoded, frame), do: read_project(path_encoded, frame)
  def read("giulia://modules/" <> path_encoded, frame), do: read_modules(path_encoded, frame)
  def read("giulia://graph/" <> path_encoded, frame), do: read_graph(path_encoded, frame)
  def read("giulia://skills/" <> category, frame), do: read_skills(category, frame)
  def read("giulia://status", frame), do: read_status(frame)

  def read(uri, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "Unknown resource URI: #{uri}"}), frame}
  end

  # --- Projects ---

  defp read_project("list", frame) do
    projects =
      Giulia.Core.ContextManager.list_projects()
      |> Enum.map(fn project -> Map.update(project, :pid, nil, &inspect/1) end)

    json_reply(%{projects: projects, count: length(projects)}, frame)
  end

  defp read_project(path_encoded, frame) do
    project_path = decode_and_resolve(path_encoded)
    summary = Giulia.Context.Store.Formatter.project_summary(project_path)
    json_reply(%{path: project_path, summary: summary}, frame)
  end

  # --- Modules ---

  defp read_modules(path_encoded, frame) do
    project_path = decode_and_resolve(path_encoded)
    modules = Giulia.Context.Store.Query.list_modules(project_path)
    json_reply(%{modules: modules, count: length(modules)}, frame)
  end

  # --- Graph ---

  defp read_graph(path_encoded, frame) do
    project_path = decode_and_resolve(path_encoded)
    stats = Giulia.Knowledge.Store.stats(project_path)
    json_reply(stats, frame)
  end

  # --- Skills ---

  defp read_skills("list", frame) do
    skills =
      Giulia.MCP.ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())

    json_reply(%{skills: skills, count: length(skills)}, frame)
  end

  defp read_skills(category, frame) do
    skills =
      Giulia.MCP.ToolSchema.routers()
      |> Enum.flat_map(& &1.__skills__())
      |> Enum.filter(&(&1.category == category))

    json_reply(%{skills: skills, count: length(skills), category: category}, frame)
  end

  # --- Status ---

  defp read_status(frame) do
    status = %{
      node: node(),
      version: Giulia.Version.short_version(),
      role: Giulia.Role.role(),
      active_projects: length(Giulia.Core.ContextManager.list_projects())
    }

    json_reply(status, frame)
  end

  # --- Helpers ---

  defp decode_and_resolve(path_encoded) do
    path_encoded
    |> URI.decode_www_form()
    |> Giulia.Core.PathMapper.resolve_path()
  end

  defp json_reply(data, frame) do
    {:reply, Response.resource() |> Response.text(Jason.encode!(data, pretty: true)), frame}
  end
end
