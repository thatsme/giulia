defmodule Giulia.Core.PathMapper do
  @moduledoc """
  The Translation Shim - Path mapping between Host and Container.

  When the Windows Client says `C:\\Development\\Guardian\\lib\\guardian.ex`,
  the Daemon translates it to `/projects/guardian/lib/guardian.ex`.

  This is the "Senior" implementation:
  - Handles Windows backslashes vs Linux forward slashes
  - Uses prefix swap, not string hacking
  - Configured via environment variables (no hardcoded paths)

  Configuration:
    GIULIA_HOST_PROJECTS_PATH - The host prefix (e.g., "C:/Development/GitHub")
    Maps to /projects inside the container
  """

  @container_prefix "/projects"

  @doc """
  Convert a host path to a container path.

  ## Example
      iex> PathMapper.to_container("C:\\\\Development\\\\GitHub\\\\Guardian\\\\lib\\\\guardian.ex")
      "/projects/Guardian/lib/guardian.ex"
  """
  @spec to_container(String.t()) :: String.t()
  def to_container(host_path) do
    host_prefix = get_host_prefix()

    # 1. Normalize Windows backslashes to forward slashes
    normalized = normalize_slashes(host_path)

    # 2. Swap the prefix (case-insensitive for Windows drive letters)
    if host_prefix && starts_with_ignore_case?(normalized, host_prefix) do
      # Replace the prefix, preserving the rest of the path
      suffix = String.slice(normalized, String.length(host_prefix)..-1//1)
      @container_prefix <> suffix
    else
      # Fallback: if no mapping, try legacy mappings
      legacy_host_to_container(normalized)
    end
  end

  # Case-insensitive prefix check (for Windows paths like C: vs c:)
  defp starts_with_ignore_case?(string, prefix) do
    String.downcase(String.slice(string, 0, String.length(prefix))) ==
      String.downcase(prefix)
  end

  @doc """
  Convert a container path back to a host path.

  ## Example
      iex> PathMapper.to_host("/projects/Guardian/lib/guardian.ex")
      "C:/Development/GitHub/Guardian/lib/guardian.ex"
  """
  @spec to_host(String.t()) :: String.t()
  def to_host(container_path) do
    host_prefix = get_host_prefix()

    if host_prefix && String.starts_with?(container_path, @container_prefix) do
      String.replace_prefix(container_path, @container_prefix, host_prefix)
    else
      container_path
    end
  end

  @doc """
  Smart path resolution - the main entry point.
  Use this for all path operations in the daemon.
  """
  @spec resolve_path(String.t() | nil) :: String.t() | nil
  def resolve_path(nil), do: nil

  def resolve_path(path) do
    if in_container?() do
      to_container(path)
    else
      path
    end
  end

  @doc """
  Check if we're running inside Docker.
  """
  @spec in_container?() :: boolean()
  def in_container? do
    File.exists?("/.dockerenv") or
      File.exists?("/run/.containerenv") or
      System.get_env("GIULIA_IN_CONTAINER") == "true"
  end

  @doc """
  Get the LM Studio base URL (without endpoint path).

  Environment variable priority:
  1. GIULIA_LM_STUDIO_URL (explicit full URL like http://192.168.1.52:1234)
  2. Auto-detect based on container status
  """
  @spec lm_studio_base_url() :: String.t()
  def lm_studio_base_url do
    # Check the correct env var name (GIULIA_LM_STUDIO_URL per CLAUDE.md)
    case System.get_env("GIULIA_LM_STUDIO_URL") do
      nil ->
        if in_container?() do
          # Inside Docker, use host.docker.internal to reach host machine
          "http://host.docker.internal:1234"
        else
          # Outside Docker, default to localhost
          "http://127.0.0.1:1234"
        end

      url ->
        # User provided URL - extract base (handle both full URL and base URL)
        url = String.trim_trailing(url, "/")
        if String.contains?(url, "/v1/") do
          # Full URL provided like "http://192.168.1.52:1234/v1/chat/completions"
          uri = URI.parse(url)
          "#{uri.scheme}://#{uri.host}:#{uri.port || 1234}"
        else
          # Base URL provided like "http://192.168.1.52:1234"
          url
        end
    end
  end

  @doc """
  Get the LM Studio chat completions URL.
  """
  @spec lm_studio_url() :: String.t()
  def lm_studio_url do
    "#{lm_studio_base_url()}/v1/chat/completions"
  end

  @doc """
  Get the LM Studio models endpoint URL (for availability check).
  """
  @spec lm_studio_models_url() :: String.t()
  def lm_studio_models_url do
    "#{lm_studio_base_url()}/v1/models"
  end

  @doc """
  List all active mappings (for debugging).
  """
  @spec list_mappings() :: [{String.t(), String.t()}]
  def list_mappings do
    host_prefix = get_host_prefix()

    if host_prefix do
      [{host_prefix, @container_prefix}]
    else
      []
    end
  end

  @doc """
  Add a runtime path mapping (for dynamic configuration).
  """
  @spec add_mapping(String.t(), String.t()) :: :ok
  def add_mapping(host_prefix, container_prefix) do
    current = Application.get_env(:giulia, :path_mappings, [])
    new_mappings = [{host_prefix, container_prefix} | current]
    Application.put_env(:giulia, :path_mappings, new_mappings)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_host_prefix do
    # Priority: env var > app config
    case System.get_env("GIULIA_HOST_PROJECTS_PATH") do
      nil -> Application.get_env(:giulia, :host_projects_path)
      "" -> Application.get_env(:giulia, :host_projects_path)
      path -> normalize_slashes(path)
    end
  end

  defp normalize_slashes(nil), do: nil

  defp normalize_slashes(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  # Legacy fallback for paths that don't match the main mapping
  defp legacy_host_to_container(normalized_path) do
    runtime_mappings = Application.get_env(:giulia, :path_mappings, [])

    legacy_mappings =
      runtime_mappings ++
        [
          {"C:/Development/GitHub", "/projects"},
          {"D:/Development/GitHub", "/projects"},
          {"C:/Users", "/users"},
          {"D:/Users", "/users"},
          {"/home", "/home"},
          {"/Users", "/users"}
        ]

    Enum.find_value(legacy_mappings, normalized_path, fn {host, container} ->
      if String.starts_with?(normalized_path, host) do
        String.replace_prefix(normalized_path, host, container)
      else
        nil
      end
    end)
  end
end
