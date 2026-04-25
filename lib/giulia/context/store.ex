defmodule Giulia.Context.Store do
  @moduledoc """
  ETS-backed store for project state.

  Holds the codebase map, AST metadata, and agent context.
  Survives terminal closure as long as the BEAM node runs.

  All AST data is namespaced by project_path to support multi-project isolation.
  ETS keys: {:ast, project_path, file_path}

  Pure ETS CRUD — query logic lives in `Store.Query`,
  formatted output in `Store.Formatter`. Narrowed in Build 146.
  """
  use GenServer

  @table __MODULE__

  @type project_path :: String.t()
  @type file_path :: String.t()
  @type module_name :: String.t()
  @type ast_data :: map()
  @type embedding_type :: :module | :function
  @type embedding_entry :: %{id: term(), vector: binary(), metadata: map()}
  @type store_stats :: %{ast_files: non_neg_integer(), total_entries: non_neg_integer()}

  # ============================================================================
  # GenServer Lifecycle
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = Giulia.EtsKeeper.claim_or_new(@table)
    {:ok, %{table: table}}
  end

  # ============================================================================
  # Raw ETS Operations
  # ============================================================================

  @doc """
  Store arbitrary key-value data.
  """
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  @doc """
  Get arbitrary key-value data.
  """
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Delete a key.
  """
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  # ============================================================================
  # AST Storage
  # ============================================================================

  @doc """
  Restore a file's AST metadata into ETS from cache (read path).
  Does NOT trigger CubDB persistence — the data is already on disk.
  Used by Loader.restore_from_cache for unchanged files.
  """
  @spec restore_ast(project_path(), file_path(), ast_data()) :: :ok
  def restore_ast(project_path, path, ast_data) do
    :ets.insert(@table, {{:ast, project_path, path}, ast_data})
    :ok
  end

  @doc """
  Store a file's AST metadata, scoped to a project (write path).
  Writes to ETS and persists to CubDB with content hash update.
  Used for new or changed files after scanning.
  """
  @spec put_ast(project_path(), file_path(), ast_data()) :: :ok
  def put_ast(project_path, path, ast_data) do
    :ets.insert(@table, {{:ast, project_path, path}, ast_data})
    Giulia.Persistence.Writer.persist_ast(project_path, path, ast_data)
    :ok
  end

  @doc """
  Get a file's AST metadata, scoped to a project.
  """
  @spec get_ast(project_path(), file_path()) :: {:ok, ast_data()} | :error
  def get_ast(project_path, path) do
    case :ets.lookup(@table, {:ast, project_path, path}) do
      [{{:ast, ^project_path, ^path}, data}] -> {:ok, data}
      [] -> :error
    end
  end

  @doc """
  Get all indexed files with their AST metadata for a project.
  """
  @spec all_asts(project_path()) :: %{file_path() => ast_data()}
  def all_asts(project_path) do
    :ets.match_object(@table, {{:ast, project_path, :_}, :_})
    |> Enum.map(fn {{:ast, _proj, path}, data} -> {path, data} end)
    |> Map.new()
  end

  @doc """
  Clear all AST data for a specific project (for re-indexing).
  """
  @spec clear_asts(project_path()) :: :ok
  def clear_asts(project_path) do
    :ets.match_delete(@table, {{:ast, project_path, :_}, :_})
    Giulia.Persistence.Writer.clear_project(project_path)
    :ok
  end

  # ============================================================================
  # Project Files
  # ============================================================================

  @doc """
  Store the master list of indexed source files for a project.
  Called by the Indexer after a scan completes.
  """
  @spec put_project_files(project_path(), [file_path()]) :: :ok
  def put_project_files(project_path, file_list) do
    :ets.insert(@table, {{:project_files, project_path}, file_list})
    Giulia.Persistence.Writer.persist_project_files(project_path, file_list)
    :ok
  end

  @doc """
  Get the list of indexed source files for a project.
  Returns [] if no scan has been performed yet.
  """
  @spec get_project_files(project_path()) :: [file_path()]
  def get_project_files(project_path) do
    case :ets.lookup(@table, {:project_files, project_path}) do
      [{{:project_files, ^project_path}, files}] -> files
      [] -> []
    end
  end

  # ============================================================================
  # Embeddings
  # ============================================================================

  @doc """
  Store embedding vectors for a project.
  Type: :module (Architectural) or :function (Surgical)
  Entries: list of %{id: key, vector: binary, metadata: map}
  """
  @spec put_embeddings(project_path(), embedding_type(), [embedding_entry()]) :: :ok
  def put_embeddings(project_path, type, entries) when type in [:module, :function] do
    :ets.insert(@table, {{:embedding, type, project_path}, entries})
    :ok
  end

  @doc """
  Get embedding vectors for a project by type.
  """
  @spec get_embeddings(project_path(), embedding_type()) :: {:ok, [embedding_entry()]} | :error
  def get_embeddings(project_path, type) when type in [:module, :function] do
    case :ets.lookup(@table, {:embedding, type, project_path}) do
      [{{:embedding, ^type, ^project_path}, entries}] -> {:ok, entries}
      [] -> :error
    end
  end

  @doc """
  Clear all embeddings for a project.
  """
  @spec clear_embeddings(project_path()) :: :ok
  def clear_embeddings(project_path) do
    :ets.delete(@table, {:embedding, :module, project_path})
    :ets.delete(@table, {:embedding, :function, project_path})
    :ok
  end

  # ============================================================================
  # Stats / Debug
  # ============================================================================

  @doc """
  Get stats about the store for a specific project.
  """
  @spec stats(project_path()) :: store_stats()
  def stats(project_path) do
    ast_count =
      length(:ets.match_object(@table, {{:ast, project_path, :_}, :_}))

    %{
      ast_files: ast_count,
      total_entries: :ets.info(@table, :size)
    }
  end

  @doc """
  Debug function to inspect what's actually in ETS for a project.
  """
  @spec debug_inspect(project_path()) :: %{files: non_neg_integer(), total_modules: non_neg_integer(), sample: list()}
  def debug_inspect(project_path) do
    require Logger

    all = all_asts(project_path)
    Logger.info("=== ETS DEBUG ===")
    Logger.info("Total AST entries: #{map_size(all)}")

    # Sample the first entry to see structure
    case Enum.take(all, 1) do
      [{path, ast_data}] ->
        Logger.info("Sample file: #{path}")
        Logger.info("AST data keys: #{inspect(Map.keys(ast_data))}")
        Logger.info("Modules raw: #{inspect(ast_data[:modules])}")
        Logger.info("Functions count: #{length(ast_data[:functions] || [])}")

      [] ->
        Logger.info("NO DATA IN ETS!")
    end

    # Count total modules across all files
    total_modules = Enum.reduce(all, 0, fn {_path, data}, acc ->
      acc + length(data[:modules] || [])
    end)

    Logger.info("Total modules across all files: #{total_modules}")
    Logger.info("=== END DEBUG ===")

    %{
      files: map_size(all),
      total_modules: total_modules,
      sample: Enum.take(all, 1)
    }
  end

end
