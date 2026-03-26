defmodule Giulia.Core.ContextManager do
  @moduledoc """
  The Traffic Controller for Multi-Project Awareness.

  This GenServer tracks which project path is handled by which ProjectContext PID.
  When a client connects from a directory, we either:
  - Route to existing ProjectContext
  - Spawn a new one under the DynamicSupervisor
  - Ask the user to /init if no GIULIA.md exists

  The Daemon's Brain: "Which project are you in? Let me connect you."
  """
  use GenServer

  require Logger

  alias Giulia.Core.ProjectContext

  @table __MODULE__

  # ============================================================================
  # Client API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get or create a ProjectContext for the given path.
  Returns {:ok, pid} or {:needs_init, path} if no GIULIA.md exists.
  """
  @spec get_context(String.t()) :: {:ok, pid()} | {:needs_init, String.t()}
  def get_context(path) do
    GenServer.call(__MODULE__, {:get_context, path})
  end

  @doc """
  Initialize a new project at the given path.
  Creates GIULIA.md and starts a ProjectContext.
  """
  @spec init_project(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def init_project(path, opts \\ []) do
    GenServer.call(__MODULE__, {:init_project, path, opts}, :infinity)
  end

  @doc """
  List all active project contexts.
  """
  @spec list_projects() :: [map()]
  def list_projects do
    GenServer.call(__MODULE__, :list_projects)
  end

  @doc """
  Shutdown a specific project context.
  """
  @spec shutdown_project(String.t()) :: :ok | {:error, :not_found}
  def shutdown_project(path) do
    GenServer.call(__MODULE__, {:shutdown_project, path})
  end

  @doc """
  Check if a project is initialized (has GIULIA.md).
  """
  @spec initialized?(String.t()) :: boolean()
  def initialized?(path) do
    File.exists?(giulia_md_path(path))
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_opts) do
    # ETS table: {normalized_path, pid, started_at}
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    Logger.info("ContextManager started - ready for multi-project awareness")
    {:ok, %{}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call({:get_context, path}, _from, state) do
    normalized = normalize_path(path)

    result =
      case lookup_context(normalized) do
        {:ok, pid} ->
          # Verify the process is still alive
          if Process.alive?(pid) do
            {:ok, pid}
          else
            # Clean up dead entry and try again
            :ets.delete(@table, normalized)
            maybe_start_context(normalized)
          end

        :not_found ->
          maybe_start_context(normalized)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:init_project, path, opts}, _from, state) do
    normalized = normalize_path(path)

    result =
      case lookup_context(normalized) do
        {:ok, pid} ->
          # Context already exists - trigger re-indexing (idempotent)
          Logger.info("Project already initialized, triggering re-index: #{normalized}")
          send(pid, :start_indexing)
          {:ok, pid}

        :not_found ->
          # New project - create structure and start context
          case create_project_structure(normalized, opts) do
            :ok ->
              start_context(normalized)

            {:error, reason} ->
              {:error, reason}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_projects, _from, state) do
    projects =
      Enum.map(:ets.tab2list(@table), fn {path, pid, started_at} ->
        %{
          path: path,
          pid: pid,
          alive: Process.alive?(pid),
          started_at: started_at
        }
      end)

    {:reply, projects, state}
  end

  @impl true
  def handle_call({:shutdown_project, path}, _from, state) do
    normalized = normalize_path(path)

    result =
      case lookup_context(normalized) do
        {:ok, pid} ->
          # Stop the ProjectContext gracefully
          DynamicSupervisor.terminate_child(Giulia.Core.ProjectSupervisor, pid)
          :ets.delete(@table, normalized)
          :ok

        :not_found ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # A ProjectContext died - clean up the ETS entry
    Logger.warning("ProjectContext #{inspect(pid)} died: #{inspect(reason)}")

    # Find and remove the dead entry
    Enum.each(:ets.tab2list(@table), fn {path, stored_pid, _} ->
      if stored_pid == pid do
        :ets.delete(@table, path)
        Logger.info("Cleaned up context for #{path}")
      end
    end)

    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp lookup_context(path) do
    case :ets.lookup(@table, path) do
      [{^path, pid, _started_at}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp maybe_start_context(path) do
    if initialized?(path) do
      start_context(path)
    else
      # Walk up to find nearest GIULIA.md
      case find_project_root(path) do
        {:ok, root} ->
          # Found a parent project - use that context
          case lookup_context(root) do
            {:ok, pid} -> {:ok, pid}
            :not_found -> start_context(root)
          end

        :not_found ->
          {:needs_init, path}
      end
    end
  end

  defp start_context(path) do
    spec = {ProjectContext, path: path}

    case DynamicSupervisor.start_child(Giulia.Core.ProjectSupervisor, spec) do
      {:ok, pid} ->
        # Monitor the process for cleanup
        Process.monitor(pid)
        :ets.insert(@table, {path, pid, DateTime.utc_now()})
        Logger.info("Started ProjectContext for #{path}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start ProjectContext for #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_project_structure(path, opts) do
    with :ok <- File.mkdir_p(path),
         :ok <- create_giulia_md(path, opts),
         :ok <- create_giulia_folder(path) do
      :ok
    end
  end

  defp create_giulia_md(path, opts) do
    file_path = giulia_md_path(path)

    # Idempotent: don't overwrite existing constitution
    if File.exists?(file_path) do
      Logger.info("GIULIA.md already exists at #{file_path}, skipping creation")
      :ok
    else
      content = build_giulia_md_content(path, opts)

      case File.write(file_path, content) do
        :ok ->
          Logger.info("Created GIULIA.md at #{file_path}")
          :ok

        {:error, reason} ->
          {:error, {:write_failed, file_path, reason}}
      end
    end
  end

  defp create_giulia_folder(path) do
    folder = Path.join(path, ".giulia")

    with :ok <- File.mkdir_p(folder),
         :ok <- File.mkdir_p(Path.join(folder, "cache")),
         :ok <- File.mkdir_p(Path.join(folder, "history")) do
      # Create .gitignore for .giulia folder
      gitignore = Path.join(folder, ".gitignore")
      File.write(gitignore, "*\n!.gitignore\n")
      :ok
    end
  end

  defp build_giulia_md_content(path, opts) do
    project_name = opts[:name] || Path.basename(path)
    tech_stack = opts[:tech_stack] || detect_tech_stack(path)

    """
    # #{project_name} - Giulia Constitution

    This file defines the rules and context for Giulia when working in this project.
    Giulia will read this file on every interaction and enforce these guidelines.

    ## Project Identity

    - **Name**: #{project_name}
    - **Root**: #{path}
    - **Created**: #{Date.utc_today()}

    ## Tech Stack

    #{format_tech_stack(tech_stack)}

    ## Architectural Guidelines

    <!-- Add your project-specific rules here -->

    - [ ] Define preferred testing approach (ExUnit, Mox, Stub)
    - [ ] Define code style preferences
    - [ ] Define architectural taboos (things Giulia should NEVER do)

    ## Taboos (Never Do This)

    <!-- Examples:
    - Never use `import` for Phoenix controllers, always use `alias`
    - Never use umbrella project structure
    - Never add dependencies without explicit approval
    -->

    ## Preferred Patterns

    <!-- Examples:
    - Use context modules for business logic
    - Prefer pipe operators for data transformation
    - Use Ecto.Multi for database transactions
    -->

    ## File Conventions

    - Test files: `test/**/*_test.exs`
    - Config files: `config/*.exs`

    ---
    *This constitution is loaded by Giulia on every interaction.*
    *Edit this file to change how Giulia behaves in this project.*
    """
  end

  defp detect_tech_stack(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) ->
        detect_elixir_stack(path)

      File.exists?(Path.join(path, "package.json")) ->
        %{language: "JavaScript/TypeScript", framework: "Node.js"}

      File.exists?(Path.join(path, "Cargo.toml")) ->
        %{language: "Rust", framework: "Cargo"}

      File.exists?(Path.join(path, "go.mod")) ->
        %{language: "Go", framework: "Go Modules"}

      true ->
        %{language: "Unknown", framework: "Unknown"}
    end
  end

  defp detect_elixir_stack(path) do
    mix_exs = Path.join(path, "mix.exs")

    content =
      case File.read(mix_exs) do
        {:ok, c} -> c
        _ -> ""
      end

    framework =
      cond do
        String.contains?(content, ":phoenix") -> "Phoenix"
        String.contains?(content, ":nerves") -> "Nerves"
        String.contains?(content, ":scenic") -> "Scenic"
        true -> "Pure Elixir"
      end

    %{language: "Elixir", framework: framework}
  end

  defp format_tech_stack(%{language: lang, framework: fw}) do
    """
    - **Language**: #{lang}
    - **Framework**: #{fw}
    """
  end

  defp format_tech_stack(_), do: "- Not detected"

  defp find_project_root(path) do
    if File.exists?(giulia_md_path(path)) do
      {:ok, path}
    else
      parent = Path.dirname(path)

      if parent == path do
        # Reached filesystem root
        :not_found
      else
        find_project_root(parent)
      end
    end
  end

  defp giulia_md_path(path), do: Path.join(path, "GIULIA.md")

  defp normalize_path(path) do
    # Don't use Path.expand on container paths - it breaks Windows paths on Linux
    # The path should already be translated by PathMapper before reaching here
    path
    |> String.replace("\\", "/")  # Normalize Windows backslashes
    |> String.trim_trailing("/")
  end
end
