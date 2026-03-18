defmodule Giulia.Context.Indexer do
  @moduledoc """
  Background GenServer for AST scanning.

  The "Brain" of Giulia - scans the project folder
  and stores AST metadata in Context.Store.

  Uses Task.async_stream for parallel processing.

  IMPORTANT: Ignores heavy directories by default:
  - node_modules (50k+ files)
  - _build (Elixir build artifacts)
  - deps (Elixir dependencies)
  - .git (version control)
  - .elixir_ls (language server cache)
  - cover (test coverage)

  This is critical for performance, especially on Windows/WSL2
  where cross-filesystem I/O is expensive.
  """
  use GenServer

  require Logger

  # Directories to ALWAYS ignore (performance critical)
  @ignore_dirs ~w(
    node_modules
    _build
    deps
    .git
    .elixir_ls
    .hex
    cover
    priv/static/assets
    __pycache__
    .venv
    venv
    target
    dist
    build
    out
    .next
    .nuxt
  )

  @type indexer_status :: %{project_path: String.t() | nil, status: :idle | :scanning, last_scan: DateTime.t() | nil, file_count: non_neg_integer()}

  # File patterns to ignore
  @ignore_patterns [
    ~r/\.beam$/,
    ~r/\.pyc$/,
    ~r/\.class$/,
    ~r/\.o$/,
    ~r/\.so$/,
    ~r/\.dll$/,
    ~r/\.min\.js$/,
    ~r/\.map$/,
    ~r/lock\.json$/,
    ~r/yarn\.lock$/,
    ~r/package-lock\.json$/,
    ~r/mix\.lock$/
  ]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Trigger a full project scan.
  """
  @spec scan(String.t()) :: :ok
  def scan(project_path) do
    GenServer.cast(__MODULE__, {:scan, project_path})
  end

  @doc """
  Alias for scan/1 - used by ProjectContext.
  """
  @spec index_path(String.t()) :: :ok
  def index_path(project_path), do: scan(project_path)

  @doc """
  Trigger a scan of a single file.
  """
  @spec scan_file(String.t()) :: :ok
  def scan_file(file_path) do
    GenServer.cast(__MODULE__, {:scan_file, file_path})
  end

  @doc """
  Alias for scan_file/1 - used by ProjectContext.
  """
  @spec index_file(String.t()) :: :ok
  def index_file(file_path), do: scan_file(file_path)

  @doc """
  Get the current indexing status.
  """
  @spec status() :: indexer_status()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    state = %{
      project_path: nil,
      status: :idle,
      last_scan: nil,
      file_count: 0
    }

    {:ok, state}
  end

  # Project root markers — at least one must exist for a valid scan target
  @project_markers ["mix.exs", "GIULIA.md", "package.json", "Cargo.toml", "go.mod"]

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast({:scan, project_path}, state) do
    if valid_project_root?(project_path) do
      Logger.info("Starting project scan: #{project_path}")
      new_state = %{state | project_path: project_path, status: :scanning}

      case Giulia.Persistence.Loader.load_project(project_path) do
        {:ok, []} ->
          # All cached, skip scan entirely
          Logger.info("Warm start: all files cached, skipping scan for #{project_path}")

          # Restore graph + metrics + embeddings from cache
          Giulia.Persistence.Loader.restore_graph(project_path)
          Giulia.Persistence.Loader.restore_metrics(project_path)
          Giulia.Persistence.Loader.restore_embeddings(project_path)

          GenServer.cast(__MODULE__, :scan_complete)
          {:noreply, new_state}

        {:ok, stale_files} ->
          # Incremental scan of stale files only
          Logger.info("Warm start: #{length(stale_files)} stale files to re-scan for #{project_path}")

          Task.start(fn ->
            do_incremental_scan(project_path, stale_files)
            GenServer.cast(__MODULE__, :scan_complete)
          end)

          {:noreply, new_state}

        {:cold_start, :no_cache} ->
          # Full scan (original behavior)
          Task.start(fn ->
            do_scan(project_path)
            GenServer.cast(__MODULE__, :scan_complete)
          end)

          {:noreply, new_state}
      end
    else
      Logger.error("SCAN REFUSED: No project root marker found at #{project_path}. " <>
        "Expected one of: #{Enum.join(@project_markers, ", ")}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:scan_file, file_path, project_path}, state) do
    Task.start(fn ->
      case process_file(file_path) do
        {:ok, ast_data} ->
          Giulia.Context.Store.put_ast(project_path, file_path, ast_data)
          Logger.debug("Indexed: #{file_path}")

        {:error, reason} ->
          Logger.warning("Failed to index #{file_path}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  # Legacy compat: scan_file without project_path uses state.project_path
  @impl true
  def handle_cast({:scan_file, file_path}, state) do
    project_path = state.project_path || File.cwd!()
    Task.start(fn ->
      case process_file(file_path) do
        {:ok, ast_data} ->
          Giulia.Context.Store.put_ast(project_path, file_path, ast_data)
          Logger.debug("Indexed: #{file_path}")

        {:error, reason} ->
          Logger.warning("Failed to index #{file_path}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_complete, state) do
    project_path = state.project_path
    stats = Giulia.Context.Store.stats(project_path)

    new_state = %{
      state
      | status: :idle,
        last_scan: DateTime.utc_now(),
        file_count: stats.ast_files
    }

    Logger.info("Scan complete. Indexed #{stats.ast_files} files.")

    # Debug: Inspect what's actually in ETS
    Giulia.Context.Store.debug_inspect(project_path)

    # Rebuild knowledge graph from fresh AST data
    Giulia.Knowledge.Store.rebuild(project_path)

    # Trigger semantic embedding (async, no-op if model unavailable)
    Giulia.Intelligence.SemanticIndex.embed_project(project_path)

    {:noreply, new_state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # Private

  defp do_incremental_scan(project_path, stale_files) do
    Logger.info("Incremental scan: re-indexing #{length(stale_files)} files")

    stale_files
    |> Task.async_stream(
      fn file -> {file, process_file(file)} end,
      max_concurrency: System.schedulers_online(),
      timeout: 30_000
    )
    |> Enum.each(fn
      {:ok, {file, {:ok, ast_data}}} ->
        Giulia.Context.Store.put_ast(project_path, file, ast_data)

      {:ok, {file, {:error, reason}}} ->
        Logger.warning("Failed to index #{file}: #{inspect(reason)}")

      {:exit, reason} ->
        Logger.error("Task crashed: #{inspect(reason)}")
    end)

    # Update project files list (merge cached + stale)
    all_files = find_elixir_files(Path.join(project_path, "lib"))
    Giulia.Context.Store.put_project_files(project_path, all_files)
    Logger.info("Incremental scan complete: #{length(stale_files)} files re-indexed")
  end

  defp do_scan(project_path) do
    lib_path = Path.join(project_path, "lib")

    if File.dir?(lib_path) do
      Giulia.Context.Store.clear_asts(project_path)

      files = find_elixir_files(lib_path)
      Logger.info("Found #{length(files)} Elixir files to scan")

      # Debug first file to understand AST structure
      case Enum.take(files, 1) do
        [first_file] ->
          Logger.info("=== DEBUG FIRST FILE ===")
          Giulia.AST.Processor.debug_file(first_file)
        _ ->
          Logger.info("No files to debug")
      end

      files
      |> Task.async_stream(
        fn file -> {file, process_file(file)} end,
        max_concurrency: System.schedulers_online(),
        timeout: 30_000
      )
      |> Enum.each(fn
        {:ok, {file, {:ok, ast_data}}} ->
          Giulia.Context.Store.put_ast(project_path, file, ast_data)

        {:ok, {file, {:error, reason}}} ->
          Logger.warning("Failed to index #{file}: #{inspect(reason)}")

        {:exit, reason} ->
          Logger.error("Task crashed: #{inspect(reason)}")
      end)

      # Store the master file list in ETS — SearchCode reads from here, not disk
      Giulia.Context.Store.put_project_files(project_path, files)
      Logger.info("Stored #{length(files)} project files in ETS file registry")
    else
      Logger.warning("No lib directory found at #{lib_path}")
    end
  end

  defp find_elixir_files(path) do
    path
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(&should_ignore?/1)
  end

  defp should_ignore?(file_path) do
    # Check if path contains any ignored directory
    path_parts = Path.split(file_path)

    dir_ignored = Enum.any?(@ignore_dirs, fn ignored_dir ->
      ignored_dir in path_parts
    end)

    # Check if file matches any ignored pattern
    pattern_ignored = Enum.any?(@ignore_patterns, fn pattern ->
      Regex.match?(pattern, file_path)
    end)

    dir_ignored or pattern_ignored
  end

  @doc """
  Get the list of ignored directories.
  """
  @spec ignored_dirs() :: [String.t()]
  def ignored_dirs, do: @ignore_dirs

  @doc """
  Check if a specific path should be ignored.
  """
  @spec ignored?(String.t()) :: boolean()
  def ignored?(path), do: should_ignore?(path)

  defp process_file(file_path) do
    # Use Sourceror-based processor for accurate AST analysis
    # Wrap in try/rescue to prevent one bad file from crashing the whole scan
    try do
      result = Giulia.AST.Processor.analyze_file(file_path)

      # Debug: Log what we extracted (use info level for prod visibility)
      case result do
        {:ok, ast_data} ->
          modules = ast_data[:modules] || []
          functions = ast_data[:functions] || []
          Logger.info("EXTRACT: #{Path.basename(file_path)} -> #{length(modules)} modules, #{length(functions)} functions")

        {:error, reason} ->
          Logger.warning("EXTRACT FAILED: #{Path.basename(file_path)} -> #{inspect(reason)}")

        _ ->
          :ok
      end

      result
    rescue
      e ->
        Logger.warning("AST parse error in #{file_path}: #{Exception.message(e)}")
        {:error, {:parse_error, Exception.message(e)}}
    catch
      :exit, reason ->
        Logger.warning("AST parse exit in #{file_path}: #{inspect(reason)}")
        {:error, {:parse_exit, reason}}
    end
  end

  defp valid_project_root?(nil), do: false

  defp valid_project_root?(path) do
    Enum.any?(@project_markers, fn marker ->
      Path.join(path, marker) |> File.exists?()
    end)
  end
end
