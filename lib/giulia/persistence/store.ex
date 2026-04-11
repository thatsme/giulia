defmodule Giulia.Persistence.Store do
  @moduledoc """
  CubDB lifecycle manager — one CubDB instance per project.

  Each project gets its own CubDB at `{project_path}/.giulia/cache/cubdb/`.
  Instances are opened lazily on first access and kept alive for the daemon's lifetime.

  Key schema (no project prefix — each project gets its own DB):
  - `{:ast, file_path}`        => ast_data map
  - `{:content_hash, file_path}` => binary (SHA-256 of raw file bytes)
  - `{:project_files}`         => [file_path]
  - `{:merkle, :tree}`         => Merkle tree struct
  - `{:graph, :serialized}`    => binary (ETF-compressed graph)
  - `{:metrics, :cached}`      => map
  - `{:embedding, type}`       => [entry]
  - `{:meta, :schema_version}` => integer
  - `{:meta, :build}`          => integer
  - `{:meta, :last_scan}`      => DateTime
  """
  use GenServer

  require Logger

  # v2: added {:mtime, file_path} keys, fixed hash/AST desync from write storm.
  # v3: AST data shape change — moduledoc preserves `false` (not nil).
  # v4: fix Enum.find_value silently dropping false (falsy) — use reduce_while.
  @schema_version 4

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Open CubDB for a project (idempotent). Returns {:ok, pid}."
  @spec open(String.t()) :: {:ok, pid()}
  def open(project_path) do
    GenServer.call(__MODULE__, {:open, project_path})
  end

  @doc "Get CubDB pid for a project, opening if needed."
  @spec get_db(String.t()) :: {:ok, pid()} | {:error, term()}
  def get_db(project_path) do
    GenServer.call(__MODULE__, {:get_db, project_path})
  end

  @doc "Close CubDB for a project."
  @spec close(String.t()) :: :ok
  def close(project_path) do
    GenServer.call(__MODULE__, {:close, project_path})
  end

  @doc "Returns the current schema version."
  @spec schema_version() :: integer()
  def schema_version, do: @schema_version

  @doc "Returns the current build number from mix.exs."
  @spec current_build() :: integer()
  def current_build do
    Mix.Project.config()[:build] || 0
  rescue
    # Mix may not be available in release mode
    _ -> Application.get_env(:giulia, :build, 0)
  end

  @doc "Trigger CubDB compaction for a project."
  @spec compact(String.t()) :: :ok | {:error, term()}
  def compact(project_path) do
    case get_db(project_path) do
      {:ok, db} ->
        CubDB.compact(db)
        :ok

      error ->
        error
    end
  end

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    {:ok, %{dbs: %{}}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call({:open, project_path}, _from, state) do
    case Map.get(state.dbs, project_path) do
      nil ->
        case do_open(project_path) do
          {:ok, db} ->
            state = %{state | dbs: Map.put(state.dbs, project_path, db)}
            {:reply, {:ok, db}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      db ->
        {:reply, {:ok, db}, state}
    end
  end

  @impl true
  def handle_call({:get_db, project_path}, _from, state) do
    case Map.get(state.dbs, project_path) do
      nil ->
        case do_open(project_path) do
          {:ok, db} ->
            state = %{state | dbs: Map.put(state.dbs, project_path, db)}
            {:reply, {:ok, db}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      db ->
        {:reply, {:ok, db}, state}
    end
  end

  @impl true
  def handle_call({:close, project_path}, _from, state) do
    case Map.pop(state.dbs, project_path) do
      {nil, _state} ->
        {:reply, :ok, state}

      {db, new_dbs} ->
        CubDB.stop(db)
        {:reply, :ok, %{state | dbs: new_dbs}}
    end
  end

  # Private

  defp do_open(project_path) do
    dir = cubdb_dir(project_path)
    File.mkdir_p!(dir)

    case CubDB.start_link(data_dir: dir, auto_compact: true) do
      {:ok, db} ->
        Logger.info("CubDB opened for #{project_path} at #{dir}")
        {:ok, db}

      {:error, reason} ->
        Logger.error("CubDB failed to open at #{dir}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cubdb_dir(project_path) do
    if Mix.env() == :test do
      # In test mode, use a temp directory to avoid corrupting the dev daemon's CubDB.
      # Two CubDB instances opening the same directory = guaranteed corruption.
      hash = Integer.to_string(:erlang.phash2(project_path))
      Path.join([System.tmp_dir!(), "giulia_test_cubdb", hash])
    else
      role = Giulia.Role.role()

      if role == :standalone do
        Path.join([project_path, ".giulia", "cache", "cubdb"])
      else
        Path.join([project_path, ".giulia", "cache", "cubdb_#{role}"])
      end
    end
  end
end
