defmodule Giulia.Core.ProjectContext do
  @moduledoc """
  Per-Project State Manager.

  Each project you work on gets its own GenServer that maintains:
  - AST index for the project files
  - Chat history (persisted to SQLite in .giulia/)
  - Constitution data (loaded from GIULIA.md)
  - Current model provider preference

  This is the "consciousness" for a single project.
  Multiple ProjectContexts can run simultaneously for different projects.
  """
  use GenServer

  require Logger

  alias Giulia.Context.{Store, Indexer}
  alias Giulia.Core.PathSandbox
  alias Giulia.Core.ProjectContext.{Constitution, History}

  defstruct [
    :path,
    :constitution,
    :constitution_path,
    :ast_index_ref,
    :history_db,
    :current_provider,
    :file_watcher_ref,
    :sandbox,
    started_at: nil,
    stats: %{
      files_indexed: 0,
      conversations: 0,
      tool_calls: 0
    },
    # Dirty state tracking for workflow hardening
    dirty_files: nil,                # MapSet of files modified since last verification
    verification_status: :clean,     # :clean | :dirty | :failed
    last_verified_at: nil,           # DateTime of last successful compile
    # Transaction mode preference (user toggle via /transaction)
    transaction_preference: false    # When true, orchestrator starts in transaction_mode
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(path))
  end

  @doc """
  Get the registry name for a project path.
  """
  @spec via_tuple(String.t()) :: {:via, module(), term()}
  def via_tuple(path) do
    {:via, Registry, {Giulia.Registry, {:project, normalize_path(path)}}}
  end

  @doc """
  Get the current constitution for this project.
  """
  @spec get_constitution(GenServer.server()) :: map() | nil
  def get_constitution(pid) do
    GenServer.call(pid, :get_constitution)
  end

  @doc """
  Reload the constitution from GIULIA.md.
  """
  @spec reload_constitution(GenServer.server()) :: :ok
  def reload_constitution(pid) do
    GenServer.call(pid, :reload_constitution)
  end

  @doc """
  Get project stats.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(pid) do
    GenServer.call(pid, :get_stats)
  end

  @doc """
  Validate a path against this project's sandbox.
  Returns {:ok, expanded_path} or {:error, :sandbox_violation}.
  """
  @spec validate_path(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, :sandbox_violation}
  def validate_path(pid, path) do
    GenServer.call(pid, {:validate_path, path})
  end

  @doc """
  Execute a sandboxed file read.
  """
  @spec read_file(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(pid, path) do
    GenServer.call(pid, {:read_file, path})
  end

  @doc """
  Execute a sandboxed file write.
  """
  @spec write_file(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_file(pid, path, content) do
    GenServer.call(pid, {:write_file, path, content})
  end

  @doc """
  Get the AST for a file in this project.
  """
  @spec get_ast(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_ast(pid, path) do
    GenServer.call(pid, {:get_ast, path})
  end

  @doc """
  Search files in this project.
  """
  @spec search_files(GenServer.server(), String.t()) :: [String.t()]
  def search_files(pid, pattern) do
    GenServer.call(pid, {:search_files, pattern})
  end

  @doc """
  Add a message to conversation history.
  """
  @spec add_to_history(GenServer.server(), String.t(), String.t()) :: :ok
  def add_to_history(pid, role, content) do
    GenServer.cast(pid, {:add_history, role, content})
  end

  @doc """
  Get recent conversation history.
  """
  @spec get_history(GenServer.server(), non_neg_integer()) :: [map()]
  def get_history(pid, limit \\ 50) do
    GenServer.call(pid, {:get_history, limit})
  end

  # ============================================================================
  # Dirty State Tracking API
  # ============================================================================

  @doc """
  Mark a file as dirty (modified since last verification).
  """
  @spec mark_dirty(GenServer.server(), String.t()) :: :ok
  def mark_dirty(pid, file_path) do
    GenServer.cast(pid, {:mark_dirty, file_path})
  end

  @doc """
  Mark the project as clean (after successful verification).
  """
  @spec mark_clean(GenServer.server()) :: :ok
  def mark_clean(pid) do
    GenServer.cast(pid, :mark_clean)
  end

  @doc """
  Mark verification as failed.
  """
  @spec mark_verification_failed(GenServer.server()) :: :ok
  def mark_verification_failed(pid) do
    GenServer.cast(pid, :mark_verification_failed)
  end

  @doc """
  Check if the project has dirty (unverified) files.
  """
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(pid) do
    GenServer.call(pid, :dirty?)
  end

  @doc """
  Get the list of dirty files.
  """
  @spec get_dirty_files(GenServer.server()) :: [String.t()]
  def get_dirty_files(pid) do
    GenServer.call(pid, :get_dirty_files)
  end

  @doc """
  Get verification status.
  """
  @spec verification_status(GenServer.server()) :: map()
  def verification_status(pid) do
    GenServer.call(pid, :verification_status)
  end

  @doc """
  Toggle transaction mode preference for this project.
  Returns the new value.
  """
  @spec toggle_transaction_preference(GenServer.server()) :: boolean()
  def toggle_transaction_preference(pid) do
    GenServer.call(pid, :toggle_transaction_preference)
  end

  @doc """
  Get the current transaction mode preference.
  """
  @spec transaction_preference(GenServer.server()) :: boolean()
  def transaction_preference(pid) do
    GenServer.call(pid, :transaction_preference)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path) |> normalize_path()

    Logger.info("Initializing ProjectContext for #{path}")

    # Create the sandbox validator
    sandbox = PathSandbox.new(path)

    # Load constitution
    constitution_path = Path.join(path, "GIULIA.md")
    constitution = Constitution.load(constitution_path)

    # Initialize history database
    history_db = History.init(path)

    state = %__MODULE__{
      path: path,
      constitution: constitution,
      constitution_path: constitution_path,
      sandbox: sandbox,
      history_db: history_db,
      started_at: DateTime.utc_now(),
      current_provider: Constitution.determine_provider(constitution),
      dirty_files: MapSet.new(),
      verification_status: :clean,
      last_verified_at: nil
    }

    # Start AST indexing in background
    send(self(), :start_indexing)

    # Watch for file changes
    send(self(), :setup_file_watcher)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_constitution, _from, state) do
    {:reply, state.constitution, state}
  end

  @impl true
  def handle_call(:reload_constitution, _from, state) do
    constitution = Constitution.load(state.constitution_path)
    new_state = %{state | constitution: constitution}
    Logger.info("Reloaded constitution for #{state.path}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      path: state.path,
      started_at: state.started_at,
      files_indexed: state.stats.files_indexed,
      conversations: state.stats.conversations,
      tool_calls: state.stats.tool_calls,
      constitution_loaded: state.constitution != nil
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:validate_path, path}, _from, state) do
    result = PathSandbox.validate(state.sandbox, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:read_file, path}, _from, state) do
    result =
      case PathSandbox.validate(state.sandbox, path) do
        {:ok, safe_path} ->
          File.read(safe_path)

        {:error, _} = error ->
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:write_file, path, content}, _from, state) do
    result =
      case PathSandbox.validate(state.sandbox, path) do
        {:ok, safe_path} ->
          # Ensure parent directory exists
          safe_path |> Path.dirname() |> File.mkdir_p()
          File.write(safe_path, content)

        {:error, _} = error ->
          error
      end

    new_state = update_stat(state, :tool_calls)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:get_ast, path}, _from, state) do
    result =
      case PathSandbox.validate(state.sandbox, path) do
        {:ok, safe_path} ->
          Store.get_ast(state.project_path, safe_path)

        {:error, _} = error ->
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:search_files, pattern}, _from, state) do
    # Search only within project sandbox
    results =
      Path.join(state.path, "**/" <> pattern)
      |> Path.wildcard()
      |> Enum.filter(&PathSandbox.safe?(&1, state.sandbox))

    {:reply, results, state}
  end

  @impl true
  def handle_call({:get_history, limit}, _from, state) do
    history = History.fetch(state.history_db, limit)
    {:reply, history, state}
  end

  # Dirty state tracking handle_call implementations
  @impl true
  def handle_call(:dirty?, _from, state) do
    is_dirty = MapSet.size(state.dirty_files || MapSet.new()) > 0
    {:reply, is_dirty, state}
  end

  @impl true
  def handle_call(:get_dirty_files, _from, state) do
    files = MapSet.to_list(state.dirty_files || MapSet.new())
    {:reply, files, state}
  end

  @impl true
  def handle_call(:verification_status, _from, state) do
    status = %{
      status: state.verification_status,
      dirty_files: MapSet.to_list(state.dirty_files || MapSet.new()),
      last_verified_at: state.last_verified_at
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:toggle_transaction_preference, _from, state) do
    new_pref = not state.transaction_preference
    {:reply, new_pref, %{state | transaction_preference: new_pref}}
  end

  @impl true
  def handle_call(:transaction_preference, _from, state) do
    {:reply, state.transaction_preference, state}
  end

  # ============================================================================
  # handle_cast implementations
  # ============================================================================

  @impl true
  def handle_cast({:add_history, role, content}, state) do
    History.insert(state.history_db, role, content)
    new_state = update_stat(state, :conversations)
    {:noreply, new_state}
  end

  # Dirty state tracking handle_cast implementations
  @impl true
  def handle_cast({:mark_dirty, file_path}, state) do
    new_dirty = MapSet.put(state.dirty_files || MapSet.new(), file_path)
    new_state = %{state |
      dirty_files: new_dirty,
      verification_status: :dirty
    }
    Logger.debug("Marked dirty: #{file_path} (#{MapSet.size(new_dirty)} dirty files)")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:mark_clean, state) do
    new_state = %{state |
      dirty_files: MapSet.new(),
      verification_status: :clean,
      last_verified_at: DateTime.utc_now()
    }
    Logger.info("Project verified clean at #{new_state.last_verified_at}")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:mark_verification_failed, state) do
    new_state = %{state | verification_status: :failed}
    Logger.warning("Verification failed - #{MapSet.size(state.dirty_files || MapSet.new())} dirty files")
    {:noreply, new_state}
  end

  # ============================================================================
  # handle_info implementations
  # ============================================================================

  @impl true
  def handle_info(:start_indexing, state) do
    Logger.info("Starting AST indexing for #{state.path}")

    # Index the project using the global indexer but scoped to our path
    Task.start(fn ->
      Indexer.index_path(state.path)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:setup_file_watcher, state) do
    # TODO: Implement FileSystem watcher for live re-indexing
    # For now, we rely on manual re-indexing
    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, path, events}, state) do
    Logger.debug("File event: #{path} - #{inspect(events)}")

    # Re-index the changed file if it's an Elixir file
    if Path.extname(path) in [".ex", ".exs"] do
      Task.start(fn ->
        Indexer.index_file(path)
      end)
    end

    # Reload constitution if GIULIA.md changed
    if Path.basename(path) == "GIULIA.md" do
      send(self(), :reload_constitution)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("ProjectContext for #{state.path} terminating: #{inspect(reason)}")
    # Close history database if open
    History.close(state.history_db)
    :ok
  end

  # ============================================================================
  # Private - Utilities
  # ============================================================================

  defp normalize_path(path) do
    # Don't use Path.expand - it breaks Windows paths on Linux
    # The path should already be translated by PathMapper
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  defp update_stat(state, key) do
    new_stats = Map.update(state.stats, key, 1, &(&1 + 1))
    %{state | stats: new_stats}
  end
end
