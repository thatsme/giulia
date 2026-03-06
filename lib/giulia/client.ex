defmodule Giulia.Client do
  @moduledoc """
  The Thin Client — facade for the Giulia daemon HTTP client.

  Delegates to focused sub-modules:
  - `Client.HTTP`      — HTTP transport (get/post)
  - `Client.Daemon`    — Docker lifecycle (start/stop/health)
  - `Client.Commands`  — Slash command dispatch
  - `Client.REPL`      — Interactive mode + multiline input
  - `Client.Renderer`  — SSE streaming + inference output
  - `Client.Approval`  — Tool execution approval gates
  - `Client.Output`    — Terminal formatting + colored messages
  """

  alias Giulia.Client.{HTTP, Daemon, Commands, Output}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Main entry point for the thin client (escript)."
  @spec main([String.t()]) :: :ok
  def main(args \\ []) do
    args = Enum.map(args, &fix_msys_path/1)

    case Daemon.ensure_running() do
      :ok ->
        Commands.process(args)

      {:error, reason} ->
        Output.error("Failed to start daemon: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc "Send a chat message to the daemon."
  @spec chat(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(message, opts \\ []) do
    path = Keyword.get(opts, :path, get_working_directory())
    HTTP.post("/api/command", %{message: message, path: path})
  end

  @doc "Initialize a project via the daemon."
  @spec init_project(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def init_project(path \\ nil, _opts \\ []) do
    host_path = path || get_working_directory()
    HTTP.post("/api/init", %{path: host_path})
  end

  @doc "Get daemon status."
  @spec status() :: {:ok, map()} | {:error, term()}
  def status do
    HTTP.get("/api/status")
  end

  @doc "List active projects."
  @spec list_projects() :: {:ok, map()} | {:error, term()}
  def list_projects do
    HTTP.get("/api/projects")
  end

  @doc "Get the real working directory (where user launched from)."
  @spec get_working_directory() :: String.t()
  def get_working_directory do
    case System.get_env("GIULIA_CLIENT_CWD") do
      nil -> File.cwd!()
      "" -> File.cwd!()
      dir -> dir
    end
  end

  # Fix MSYS/Git Bash path mangling on Windows.
  defp fix_msys_path(arg) do
    msys_prefix = "C:/Program Files/Git/"

    if String.starts_with?(arg, msys_prefix) do
      "/" <> String.replace_prefix(arg, msys_prefix, "")
    else
      arg
    end
  end
end
