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

  @type project_status :: %{status: :idle | :scanning | :empty, last_scan: DateTime.t() | nil, file_count: non_neg_integer()}
  @type indexer_status :: %{project_path: String.t() | nil, status: :idle | :scanning | :empty, last_scan: DateTime.t() | nil, file_count: non_neg_integer()}

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

  ## Options

    * `:force` (boolean, default false) — when true, bypass the L2 warm-cache
      short-circuit and always cold-extract from disk. Use this after editing
      the extractor or graph builder to make sure the next scan reflects the
      new code; otherwise stale cached ASTs / graphs / metrics would survive.
  """
  @spec scan(String.t(), keyword()) :: :ok
  def scan(project_path, opts \\ []) do
    GenServer.cast(__MODULE__, {:scan, project_path, opts})
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
  Get the indexing status. Without a path, returns the last-active project's status
  (backward compatible). With a path, returns that project's status.
  """
  @spec status() :: indexer_status()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec status(String.t()) :: indexer_status()
  def status(project_path), do: GenServer.call(__MODULE__, {:status, project_path})

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    # Per-project state: %{project_path => %{status, last_scan, file_count}}
    {:ok, %{projects: %{}, last_project: nil}}
  end

  defp get_project_status(state, project_path) do
    Map.get(state.projects, project_path, %{status: :idle, last_scan: nil, file_count: 0})
  end

  defp put_project_status(state, project_path, project_state) do
    %{state | projects: Map.put(state.projects, project_path, project_state), last_project: project_path}
  end

  # Project root markers — at least one must exist for a valid scan target
  @project_markers ["mix.exs", "GIULIA.md", "package.json", "Cargo.toml", "go.mod"]

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast({:scan, project_path, opts}, state) do
    force? = Keyword.get(opts, :force, false)

    if valid_project_root?(project_path) do
      Logger.info(
        "Starting project scan: #{project_path}#{if force?, do: " (force=true)", else: ""}"
      )

      new_state =
        put_project_status(state, project_path, %{status: :scanning, last_scan: nil, file_count: 0})

      cond do
        force? ->
          # Bypass warm-cache entirely. Cold-extract from disk so any
          # extractor/builder code change is reflected in the next scan.
          Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
            do_scan(project_path)
            GenServer.cast(__MODULE__, {:scan_complete, project_path})
          end)

          {:noreply, new_state}

        true ->
          case Giulia.Persistence.Loader.load_project(project_path) do
            {:ok, []} ->
              # All cached, skip scan entirely
              Logger.info("Warm start: all files cached, skipping scan for #{project_path}")

              # Restore graph + metrics + embeddings from cache
              Giulia.Persistence.Loader.restore_graph(project_path)
              Giulia.Persistence.Loader.restore_metrics(project_path)
              Giulia.Persistence.Loader.restore_embeddings(project_path)

              GenServer.cast(__MODULE__, {:scan_complete, project_path})
              {:noreply, new_state}

            {:ok, stale_files} ->
              # Incremental scan of stale files only
              Logger.info(
                "Warm start: #{length(stale_files)} stale files to re-scan for #{project_path}"
              )

              Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
                do_incremental_scan(project_path, stale_files)
                GenServer.cast(__MODULE__, {:scan_complete, project_path})
              end)

              {:noreply, new_state}

            {:cold_start, :no_cache} ->
              # Full scan (original behavior)
              Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
                do_scan(project_path)
                GenServer.cast(__MODULE__, {:scan_complete, project_path})
              end)

              {:noreply, new_state}
          end
      end
    else
      Logger.error(
        "SCAN REFUSED: No project root marker found at #{project_path}. " <>
          "Expected one of: #{Enum.join(@project_markers, ", ")}"
      )

      {:noreply, state}
    end
  end

  # Backward compat: callers using the old 2-tuple cast pattern.
  def handle_cast({:scan, project_path}, state) do
    handle_cast({:scan, project_path, []}, state)
  end

  @impl true
  def handle_cast({:scan_file, file_path, project_path}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
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

  # Legacy compat: scan_file without project_path uses last_project
  @impl true
  def handle_cast({:scan_file, file_path}, state) do
    project_path = state.last_project || File.cwd!()
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
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
  def handle_cast({:scan_complete, project_path}, state) do
    stats = Giulia.Context.Store.stats(project_path)

    # A successful scan that indexed zero files is almost certainly a
    # bug, not a valid state — wrong path, over-aggressive ignore
    # rules, or a directory with only dependencies. Surface it as
    # `:empty` so clients can distinguish "scan complete, nothing to
    # do" from "scan complete, 0 files found — someone should look."
    status = if stats.ast_files == 0, do: :empty, else: :idle

    project_state = %{
      status: status,
      last_scan: DateTime.utc_now(),
      file_count: stats.ast_files
    }

    new_state = put_project_status(state, project_path, project_state)

    if stats.ast_files == 0 do
      Logger.warning(
        "[Indexer] Scan of #{project_path} completed with 0 indexed files — " <>
          "project appears empty or all files were filtered. Status set to :empty."
      )
    else
      Logger.info("Scan complete for #{project_path}. Indexed #{stats.ast_files} files.")
    end

    # Debug: Inspect what's actually in ETS
    Giulia.Context.Store.debug_inspect(project_path)

    # Ensure project is compiled so xref has BEAM files for graph building
    ensure_compiled(project_path)

    # Rebuild knowledge graph from fresh AST data
    Giulia.Knowledge.Store.rebuild(project_path)

    # Trigger semantic embedding (async, no-op if model unavailable)
    Giulia.Intelligence.SemanticIndex.embed_project(project_path)

    {:noreply, new_state}
  end

  # Backward compat: old :scan_complete without project_path
  @impl true
  def handle_cast(:scan_complete, state) do
    if state.last_project do
      handle_cast({:scan_complete, state.last_project}, state)
    else
      Logger.warning("scan_complete received with no project context — ignoring")
      {:noreply, state}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call({:status, project_path}, _from, state) do
    ps = get_project_status(state, project_path)
    # Return backward-compatible shape with project_path included
    reply = Map.put(ps, :project_path, project_path)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    # Backward compat: return last-active project's status
    case state.last_project do
      nil ->
        {:reply, %{project_path: nil, status: :idle, last_scan: nil, file_count: 0}, state}

      path ->
        ps = get_project_status(state, path)
        reply = Map.put(ps, :project_path, path)
        {:reply, reply, state}
    end
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
    all_files =
      project_path
      |> find_files_across_roots()
      |> maybe_include_mix_exs(project_path)

    Giulia.Context.Store.put_project_files(project_path, all_files)
    Logger.info("Incremental scan complete: #{length(stale_files)} files re-indexed")
  end

  defp do_scan(project_path) do
    roots = Giulia.Context.ScanConfig.absolute_roots(project_path)

    if roots != [] do
      Giulia.Context.Store.clear_asts(project_path)

      files =
        project_path
        |> find_files_across_roots()
        |> maybe_include_mix_exs(project_path)

      Logger.info("Found #{length(files)} Elixir files to scan across roots: #{inspect(roots)}")

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
      Logger.warning(
        "No configured source roots exist under #{project_path} " <>
          "(checked: #{inspect(Giulia.Context.ScanConfig.source_roots())})"
      )
    end
  end

  defp find_elixir_files(path) do
    path
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(&should_ignore?/1)
  end

  # Walk every configured source root under a project and return the
  # flat, deduplicated list of Elixir source files. Entries that don't
  # exist are dropped by ScanConfig.absolute_roots/1; remaining entries
  # may be directories (walked recursively) or individual .ex/.exs files
  # (included as-is).
  defp find_files_across_roots(project_path) do
    project_path
    |> Giulia.Context.ScanConfig.absolute_roots()
    |> Enum.flat_map(fn entry ->
      cond do
        File.dir?(entry) ->
          find_elixir_files(entry)

        File.regular?(entry) and String.ends_with?(entry, [".ex", ".exs"]) and
            not should_ignore?(entry) ->
          [entry]

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  # mix.exs lives at the project root (outside lib/) but defines the top-level
  # application module (`mod: {Foo.Application, []}`) and referenced modules.
  # Including it in the scan lets the graph see those references.
  defp maybe_include_mix_exs(files, project_path) do
    mix_path = Path.join(project_path, "mix.exs")
    if File.exists?(mix_path), do: [mix_path | files], else: files
  end

  defp should_ignore?(file_path) do
    # Check if path contains any ignored directory. `@ignore_dirs` may
    # hold single-segment entries ("node_modules") OR multi-segment
    # entries ("priv/static/assets"). For single-segment entries a split-
    # and-match is enough; for multi-segment entries we need to look for
    # the slash-wrapped substring because Path.split would never produce
    # a single part equal to a compound path.
    path_parts = Path.split(file_path)

    dir_ignored =
      Enum.any?(@ignore_dirs, fn ignored_dir ->
        if String.contains?(ignored_dir, "/") do
          String.contains?(file_path, "/" <> ignored_dir <> "/") or
            String.ends_with?(file_path, "/" <> ignored_dir)
        else
          ignored_dir in path_parts
        end
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

  defp ensure_compiled(project_path) do
    mix_file = Path.join(project_path, "mix.exs")

    if File.exists?(mix_file) do
      build_path = giulia_build_path(project_path)

      Logger.info("Compiling #{project_path} for xref analysis (build: #{build_path})")

      try do
        # Always run `mix deps.get`. Mix considers a dep "not available" if
        # its tracking state (mix.lock registration, .fetch markers) is out
        # of sync with the filesystem, even when deps/<name>/ is populated
        # from a prior partial checkout. The previous `File.dir?("deps")`
        # guard treated a half-populated deps/ as "done" and skipped the
        # reconcile, which made `mix compile` fail with "Unchecked
        # dependencies" and xref quietly never run. deps.get is idempotent
        # and <1s when up-to-date; always-run costs little and closes the
        # gap.
        Logger.info("Fetching deps for #{project_path}...")

        {deps_output, deps_exit} =
          System.cmd("mix", ["deps.get"], cd: project_path, stderr_to_stdout: true)

        if deps_exit != 0 do
          Logger.warning(
            "mix deps.get failed for #{project_path} (exit #{deps_exit}): " <>
              String.slice(deps_output, 0, 500)
          )
        end

        # Compile with project-specific build path to isolate multi-project builds.
        # MIX_BUILD_PATH overrides _build/{env} so each project gets its own BEAM output.
        {output, exit_code} =
          System.cmd("mix", ["compile"],
            cd: project_path,
            stderr_to_stdout: true,
            env: [{"MIX_BUILD_PATH", build_path}, {"MIX_ENV", "dev"}]
          )

        if exit_code == 0 do
          app_name = infer_app_name(project_path)
          ebin = Path.join([build_path, "lib", app_name, "ebin"])
          beam_count = if File.dir?(ebin), do: ebin |> File.ls!() |> Enum.count(&String.ends_with?(&1, ".beam")), else: 0
          Logger.info("Compiled #{project_path} successfully (#{beam_count} BEAM files in #{ebin})")
        else
          Logger.warning("Compilation failed for #{project_path} (exit #{exit_code}): #{String.slice(output, 0, 500)}")
        end
      rescue
        e -> Logger.warning("Failed to compile #{project_path}: #{Exception.message(e)}")
      end
    end
  end

  @doc false
  @spec giulia_build_path(String.t()) :: String.t()
  def giulia_build_path(project_path) do
    hash =
      :crypto.hash(:md5, project_path)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    Path.join(["/tmp/giulia_build", "targets", hash])
  end

  defp infer_app_name(project_path) do
    mix_path = Path.join(project_path, "mix.exs")

    case File.read(mix_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> Path.basename(project_path)
        end

      _ -> Path.basename(project_path)
    end
  end

  @doc """
  List the filenames that identify a directory as a project root.
  Public so the HTTP layer can report expected markers in 422 errors.
  """
  @spec project_markers() :: [String.t()]
  def project_markers, do: @project_markers

  @doc """
  Returns true iff `path` is a binary pointing at a directory that
  contains at least one of `project_markers/0`. Public so the HTTP
  layer can validate upfront and reject with 422 instead of
  accepting a cast that the scan handler will silently refuse.
  """
  @spec valid_project_root?(term()) :: boolean()
  def valid_project_root?(nil), do: false

  def valid_project_root?(path) when is_binary(path) do
    Enum.any?(@project_markers, fn marker ->
      File.exists?(Path.join(path, marker))
    end)
  end

  def valid_project_root?(_), do: false
end
