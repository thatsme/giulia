defmodule Giulia.Core.PathMapper do
  @moduledoc """
  Host↔container path translation.

  Giulia runs inside a container while its clients run on the host. A client
  speaks host paths — `D:/Development/GitHub/Giulia` under Docker Desktop on
  Windows, `/Users/alex/dev/Giulia` under OrbStack on macOS — and the daemon
  resolves them against the mount that carries them into the container.

  Every mapping comes from the environment. No host path is compiled in, so a
  single image behaves identically on every platform: a difference in behaviour
  can only follow from a difference in configuration.

  ## Configuration

    * `GIULIA_HOST_PROJECTS_PATH` — host prefix mounted at `/projects`
    * `GIULIA_PATH_MAPPING` — additional pairs, `host=container`, `;`-separated

  ## Matching rules

  Longest prefix wins, so a specific mapping is never shadowed by a shorter one
  sharing its head. A prefix matches only on a path-segment boundary:
  `/Users/alex/dev` maps `/Users/alex/dev/app` but never `/Users/alex/devil`.
  Comparison ignores case only for prefixes beginning with a Windows drive
  letter — `/Users` and `/users` are two different directories on the Linux
  filesystem inside the container, and treating them as one silently rewrites
  macOS paths to a location that does not exist.

  An unmapped path is returned unchanged. `diagnostics/0` reports the active
  table and is surfaced on `GET /health`, so a wrong mount shows up in one
  request instead of as an empty scan result much later.
  """

  require Logger

  @container_prefix "/projects"

  @doc """
  Convert a host path to a container path.

  With `GIULIA_HOST_PROJECTS_PATH=D:/Development/GitHub`, the host path
  `D:/Development/GitHub/Giulia/mix.exs` becomes `/projects/Giulia/mix.exs`.
  Returns the input unchanged when no mapping applies.
  """
  @spec to_container(String.t()) :: String.t()
  def to_container(host_path) do
    normalized = normalize_slashes(host_path)

    swap(normalized, by_host_length(), fn {host, container} -> {host, container} end)
  end

  @doc """
  Convert a container path back to a host path.

  The inverse of `to_container/1`. Returns the input unchanged when no mapping
  applies — a container-only path such as `/tmp/x` has no host equivalent.
  """
  @spec to_host(String.t()) :: String.t()
  def to_host(container_path) do
    normalized = normalize_slashes(container_path)

    swap(normalized, by_container_length(), fn {host, container} -> {container, host} end)
  end

  @doc """
  Smart path resolution — the main entry point for daemon code.

  Inside a container, translates a host path to its container equivalent.
  Outside one, host and container paths are the same thing, so the path is
  returned as given.
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

  @doc "Check if we're running inside a container."
  @spec in_container?() :: boolean()
  def in_container? do
    File.exists?("/.dockerenv") or
      File.exists?("/run/.containerenv") or
      System.get_env("GIULIA_IN_CONTAINER") == "true"
  end

  @doc """
  Active host→container mappings, in resolution order.

  `GIULIA_PATH_MAPPING` pairs come first, then any added by `add_mapping/2`,
  then the `GIULIA_HOST_PROJECTS_PATH` → `/projects` pair. Source order only
  breaks ties: `to_container/1` and `to_host/1` both prefer the longest prefix.
  """
  @spec list_mappings() :: [{String.t(), String.t()}]
  def list_mappings do
    env_pairs() ++ runtime_pairs() ++ projects_pair()
  end

  @doc """
  Add a runtime path mapping.

  Useful when a project is mounted somewhere the environment does not describe.
  """
  @spec add_mapping(String.t(), String.t()) :: :ok
  def add_mapping(host_prefix, container_prefix) do
    current = Application.get_env(:giulia, :path_mappings, [])
    Application.put_env(:giulia, :path_mappings, [{host_prefix, container_prefix} | current])
    :ok
  end

  @doc """
  Report the active mapping table and whether it can translate host paths.

  `warning` is `nil` when the configuration is usable, and a sentence when it is
  not — the daemon is running in a container with nothing to translate against,
  which makes every host path from a client resolve to itself and then fail to
  open.
  """
  @spec diagnostics() :: map()
  def diagnostics do
    mappings = list_mappings()

    %{
      in_container: in_container?(),
      mappings:
        Enum.map(mappings, fn {host, container} -> %{host: host, container: container} end),
      warning: mapping_warning(mappings)
    }
  end

  @doc """
  Log the mapping table at boot, loudly if it cannot translate anything.

  Called from the application supervisor so a bad mount is visible in the first
  lines of `docker compose logs` rather than as a confusing empty scan.
  """
  @spec log_configuration() :: :ok
  def log_configuration do
    case diagnostics() do
      %{warning: nil, mappings: mappings} ->
        Logger.info("PathMapper: #{length(mappings)} host→container mapping(s) active")

      %{warning: warning} ->
        Logger.warning("PathMapper: #{warning}")
    end

    :ok
  end

  @doc """
  Get the LM Studio base URL (without endpoint path).

  Environment variable priority:
  1. GIULIA_LM_STUDIO_URL (explicit full URL like http://192.168.1.52:1234)
  2. Auto-detect based on container status
  """
  @spec lm_studio_base_url() :: String.t()
  def lm_studio_base_url do
    case System.get_env("GIULIA_LM_STUDIO_URL") do
      nil ->
        if in_container?() do
          "http://host.docker.internal:1234"
        else
          "http://127.0.0.1:1234"
        end

      url ->
        url = String.trim_trailing(url, "/")

        if String.contains?(url, "/v1/") do
          uri = URI.parse(url)
          "#{uri.scheme}://#{uri.host}:#{uri.port || 1234}"
        else
          url
        end
    end
  end

  @doc "Get the LM Studio chat completions URL."
  @spec lm_studio_url() :: String.t()
  def lm_studio_url do
    "#{lm_studio_base_url()}/v1/chat/completions"
  end

  @doc "Get the LM Studio models endpoint URL (for availability check)."
  @spec lm_studio_models_url() :: String.t()
  def lm_studio_models_url do
    "#{lm_studio_base_url()}/v1/models"
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Rewrites the first prefix that matches, or returns the path untouched.
  # `orient` picks which side of each pair is the source and which the target,
  # so one traversal serves both translation directions.
  defp swap(path, mappings, orient) do
    Enum.find_value(mappings, path, fn pair ->
      {from, to} = orient.(pair)

      if prefix_match?(path, from) do
        to <> String.slice(path, String.length(from)..-1//1)
      end
    end)
  end

  defp by_host_length, do: Enum.sort_by(list_mappings(), &String.length(elem(&1, 0)), :desc)

  defp by_container_length, do: Enum.sort_by(list_mappings(), &String.length(elem(&1, 1)), :desc)

  # A prefix matches only on a segment boundary, so `/a/dev` never claims
  # `/a/devil`. Case is ignored only for Windows drive-letter prefixes.
  defp prefix_match?(_path, prefix) when prefix in [nil, ""], do: false

  defp prefix_match?(path, prefix) do
    len = String.length(prefix)
    head = String.slice(path, 0, len)
    rest = String.slice(path, len..-1//1)

    same_head?(head, prefix) and (rest == "" or String.starts_with?(rest, "/"))
  end

  defp same_head?(head, prefix) do
    if windows_prefix?(prefix) do
      String.downcase(head) == String.downcase(prefix)
    else
      head == prefix
    end
  end

  defp windows_prefix?(prefix), do: Regex.match?(~r/^[A-Za-z]:/, prefix)

  defp env_pairs, do: parse_mapping_spec(System.get_env("GIULIA_PATH_MAPPING"))

  defp parse_mapping_spec(nil), do: []
  defp parse_mapping_spec(""), do: []

  defp parse_mapping_spec(spec) do
    spec
    |> String.split(";")
    |> Enum.flat_map(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [host, container] -> mapping_pair(host, container)
        _ -> []
      end
    end)
  end

  defp mapping_pair(host, container) do
    host = normalize_slashes(String.trim(host))
    container = normalize_slashes(String.trim(container))

    if host != "" and container != "", do: [{host, container}], else: []
  end

  defp runtime_pairs do
    :giulia
    |> Application.get_env(:path_mappings, [])
    |> Enum.flat_map(fn {host, container} -> mapping_pair(host, container) end)
  end

  defp projects_pair do
    case get_host_prefix() do
      nil -> []
      "" -> []
      prefix -> [{prefix, @container_prefix}]
    end
  end

  defp get_host_prefix do
    case System.get_env("GIULIA_HOST_PROJECTS_PATH") do
      nil -> normalize_slashes(Application.get_env(:giulia, :host_projects_path))
      "" -> normalize_slashes(Application.get_env(:giulia, :host_projects_path))
      path -> normalize_slashes(path)
    end
  end

  defp mapping_warning([]) do
    if in_container?() do
      "no host→container path mappings configured — set GIULIA_HOST_PROJECTS_PATH " <>
        "to the host side of the /projects mount, or host paths sent by clients " <>
        "will resolve to themselves and fail to open"
    end
  end

  defp mapping_warning(_), do: nil

  defp normalize_slashes(nil), do: nil

  defp normalize_slashes(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end
end
