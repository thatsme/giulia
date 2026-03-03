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
  def build_tool_opts(state) do
    opts = []

    opts =
      if state.project_path do
        Keyword.put(opts, :project_path, state.project_path)
      else
        opts
      end

    opts =
      if state.project_pid do
        Keyword.put(opts, :project_pid, state.project_pid)
      else
        opts
      end

    opts =
      if state.project_path do
        sandbox = PathSandbox.new(state.project_path)
        Keyword.put(opts, :sandbox, sandbox)
      else
        opts
      end

    opts
  end

  @doc "Resolve a tool path through the sandbox."
  def resolve_tool_path(nil, _state), do: nil

  def resolve_tool_path(path, state) do
    if state.project_path do
      sandbox = PathSandbox.new(state.project_path)

      case PathSandbox.validate(sandbox, path) do
        {:ok, resolved} -> resolved
        {:error, _} -> path
      end
    else
      path
    end
  end

  @doc "Get working directory for display."
  def get_working_directory(state) do
    if state.project_path do
      PathMapper.to_host(state.project_path)
    else
      File.cwd!()
    end
  end

  @doc "Get constitution from ProjectContext pid."
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
    case Store.find_module(project_path, module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end

  defp extract_file_from_text(text) do
    case Regex.run(~r/(?:lib|test)\/[\w\/]+\.(?:ex|exs)/, text) do
      [match] -> match
      nil -> nil
    end
  end
end
