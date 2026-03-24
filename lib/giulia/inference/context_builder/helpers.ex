defmodule Giulia.Inference.ContextBuilder.Helpers do
  @moduledoc """
  Shared utilities for ContextBuilder sub-modules.

  Tool opts, path resolution, param formatting, file extraction.
  """

  alias Giulia.Context.Store
  alias Giulia.Core.{PathMapper, PathSandbox}
  alias Giulia.Tools.Registry

  # ============================================================================
  # Tool Opts & Path Resolution
  # ============================================================================

  @doc "Build standard tool opts from state."
  @spec build_tool_opts(map()) :: keyword()
  def build_tool_opts(%{project_path: nil}), do: []

  def build_tool_opts(%{project_path: path, project_pid: pid}) do
    sandbox = PathSandbox.new(path)

    [project_path: path, sandbox: sandbox]
    |> maybe_put(:project_pid, pid)
  end

  def build_tool_opts(%{project_path: _path} = state) do
    build_tool_opts(Map.put_new(state, :project_pid, nil))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Resolve a tool path through the sandbox."
  @spec resolve_tool_path(String.t() | nil, map()) :: String.t() | nil
  def resolve_tool_path(nil, _state), do: nil
  def resolve_tool_path(path, %{project_path: nil}), do: path

  def resolve_tool_path(path, %{project_path: project_path}) do
    sandbox = PathSandbox.new(project_path)

    case PathSandbox.validate(sandbox, path) do
      {:ok, resolved} -> resolved
      {:error, _} -> path
    end
  end

  @doc "Get working directory for display."
  @spec get_working_directory(map()) :: String.t()
  def get_working_directory(%{project_path: nil}), do: File.cwd!()
  def get_working_directory(%{project_path: path}), do: PathMapper.to_host(path)

  @doc "Get constitution from ProjectContext pid."
  @spec get_constitution(pid() | nil) :: String.t() | nil
  def get_constitution(nil), do: nil

  def get_constitution(pid) when is_pid(pid) do
    try do
      Giulia.Core.ProjectContext.get_constitution(pid)
    catch
      :exit, _ -> nil
    end
  end

  # ============================================================================
  # Param Formatting
  # ============================================================================

  @doc "Format params as a brief string."
  @spec format_params_brief(map()) :: String.t()
  def format_params_brief(params) when is_map(params) do
    params
    |> Enum.take(2)
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v), do: String.slice(v, 0, 20), else: inspect(v)
      "#{k}: #{v_str}"
    end)
    |> Enum.join(", ")
  end

  @doc "Sanitize params for broadcasting (truncate large content)."
  @spec sanitize_params_for_broadcast(map() | term()) :: map() | term()
  def sanitize_params_for_broadcast(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} ->
      if is_binary(v) and byte_size(v) > 500 do
        {k, String.slice(v, 0, 500) <> "... (truncated)"}
      else
        {k, v}
      end
    end)
    |> Map.new()
  end

  def sanitize_params_for_broadcast(params), do: params

  # ============================================================================
  # File Extraction
  # ============================================================================

  @doc "Extract the target file from state (task description + action history)."
  @spec extract_target_file(map()) :: String.t() | nil
  def extract_target_file(state) do
    task_file = extract_file_from_text(state.task)

    action_file =
      state.action_history
      |> Enum.find_value(fn
        {tool, params, _}
        when tool in ["read_file", "edit_file", "write_file", "write_function", "patch_function"] ->
          params["file"] || params["path"] || params[:file] || params[:path] ||
            lookup_module_file(params["module"] || params[:module], state.project_path)

        {_, _, _} ->
          nil
      end)

    task_file || action_file
  end

  @doc "Read fresh content for a file path (uses Registry for sandbox)."
  @spec read_fresh_content(String.t(), map()) :: String.t() | nil
  def read_fresh_content(file_path, state) do
    tool_opts = build_tool_opts(state)

    case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
      {:ok, content} ->
        if String.length(content) > 3000 do
          String.slice(content, 0, 3000) <> "\n\n... [truncated]"
        else
          content
        end

      {:error, _} ->
        nil
    end
  end

  # Private helpers

  defp lookup_module_file(nil, _project_path), do: nil

  defp lookup_module_file(module_name, project_path) do
    case Store.Query.find_module(project_path, module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end

  defp extract_file_from_text(text) do
    case Regex.run(~r/(?:lib|test)\/[\w\/]+\.(?:exs|ex)/, text) do
      [match] -> match
      nil -> nil
    end
  end
end
