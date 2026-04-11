defmodule Giulia.Persistence.Loader do
  @moduledoc """
  Startup recovery — restores cached AST data from CubDB into ETS.

  Not a GenServer — called once during Indexer's scan startup to determine
  whether a full re-scan is needed or if cached data can be used.

  Returns:
  - `{:ok, []}` — all cached, zero stale files, skip scan entirely
  - `{:ok, stale_files}` — partial cache hit, only re-scan listed files
  - `{:cold_start, :no_cache}` — no cache or incompatible version, full scan needed
  """

  require Logger

  @doc """
  Attempt to restore a project's AST data from CubDB into ETS.

  Checks schema version and build compatibility, then validates each
  cached file against its current content hash on disk.
  """
  @spec load_project(String.t()) :: {:ok, [String.t()]} | {:cold_start, :no_cache}
  def load_project(project_path) do
    case Giulia.Persistence.Store.get_db(project_path) do
      {:ok, db} ->
        with :ok <- check_compatibility(db) do
          restore_from_cache(db, project_path)
        else
          {:incompatible, reason} ->
            Logger.info("Cache incompatible for #{project_path}: #{reason}")
            {:cold_start, :no_cache}
        end

      {:error, reason} ->
        Logger.info("No CubDB available for #{project_path}: #{inspect(reason)}")
        {:cold_start, :no_cache}
    end
  end

  @doc """
  Restore knowledge graph from CubDB (only if zero stale files).
  Returns :ok or :not_cached.
  """
  @spec restore_graph(String.t()) :: :ok | :not_cached
  def restore_graph(project_path) do
    case Giulia.Persistence.Store.get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:graph, :serialized}) do
          nil ->
            :not_cached

          binary when is_binary(binary) ->
            try do
              graph = :erlang.binary_to_term(binary)
              Giulia.Knowledge.Store.restore_graph(project_path, graph)
              Logger.info("Restored knowledge graph from cache for #{project_path}")
              :ok
            rescue
              e ->
                Logger.warning("Corrupt graph cache for #{project_path}: #{Exception.message(e)}")
                :not_cached
            end

          _other ->
            Logger.warning("Unexpected graph cache format for #{project_path}")
            :not_cached
        end

      _ ->
        :not_cached
    end
  end

  @doc """
  Restore cached metrics from CubDB.
  Returns :ok or :not_cached.
  """
  @spec restore_metrics(String.t()) :: :ok | :not_cached
  def restore_metrics(project_path) do
    case Giulia.Persistence.Store.get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:metrics, :cached}) do
          nil ->
            :not_cached

          metrics when is_map(metrics) ->
            Giulia.Knowledge.Store.restore_metrics(project_path, metrics)
            Logger.info("Restored metric cache from disk for #{project_path}")
            :ok

          _other ->
            Logger.warning("Unexpected metrics cache format for #{project_path}")
            :not_cached
        end

      _ ->
        :not_cached
    end
  end

  @doc """
  Restore cached embeddings from CubDB.
  Returns :ok or :not_cached.
  """
  @spec restore_embeddings(String.t()) :: :ok | :not_cached
  def restore_embeddings(project_path) do
    case Giulia.Persistence.Store.get_db(project_path) do
      {:ok, db} ->
        restored =
          for type <- [:module, :function], reduce: false do
            acc ->
              case CubDB.get(db, {:embedding, type}) do
                nil ->
                  acc

                entries when is_list(entries) ->
                  Giulia.Context.Store.put_embeddings(project_path, type, entries)
                  Logger.info("Restored #{type} embeddings from cache (#{length(entries)} entries)")
                  true

                _other ->
                  Logger.warning("Unexpected #{type} embedding cache format for #{project_path}")
                  acc
              end
          end

        if restored, do: :ok, else: :not_cached

      _ ->
        :not_cached
    end
  end

  @doc """
  Get the Merkle tree root hash from cache, if available.
  """
  @spec cached_merkle_root(String.t()) :: {:ok, binary()} | :not_cached
  def cached_merkle_root(project_path) do
    case Giulia.Persistence.Store.get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:merkle, :tree}) do
          nil -> :not_cached
          tree -> {:ok, Giulia.Persistence.Merkle.root_hash(tree)}
        end

      _ ->
        :not_cached
    end
  end

  # Private

  defp check_compatibility(db) do
    stored_schema = CubDB.get(db, {:meta, :schema_version})
    stored_build = CubDB.get(db, {:meta, :build})
    current_schema = Giulia.Persistence.Store.schema_version()
    current_build = Giulia.Persistence.Store.current_build()

    cond do
      is_nil(stored_schema) ->
        {:incompatible, "no schema version (fresh DB)"}

      stored_schema != current_schema ->
        {:incompatible, "schema v#{stored_schema} != v#{current_schema}"}

      is_nil(stored_build) ->
        {:incompatible, "no build number (incomplete metadata)"}

      is_integer(stored_build) and is_integer(current_build) and stored_build > current_build ->
        {:incompatible, "stored build #{stored_build} > current #{current_build} (downgrade)"}

      true ->
        :ok
    end
  end

  defp restore_from_cache(db, project_path) do
    # Collect all cached AST entries
    cached_entries =
      Enum.to_list(CubDB.select(db, min_key: {:ast, ""}, max_key: {:ast, <<255>>}))

    if cached_entries == [] do
      {:cold_start, :no_cache}
    else
      {restored, stale} = classify_entries(db, project_path, cached_entries)

      # Detect NEW files on disk that aren't in the cache
      new_files = discover_new_files(project_path, cached_entries)

      if new_files != [] do
        Logger.info("Cache restore: #{length(new_files)} new files detected on disk")
      end

      # Restore valid (unchanged) entries to ETS only — no CubDB write-back.
      # These are already persisted on disk with correct hashes.
      Enum.each(restored, fn {file_path, ast_data} ->
        Giulia.Context.Store.restore_ast(project_path, file_path, ast_data)
      end)

      # Restore project files list
      case CubDB.get(db, {:project_files}) do
        nil -> :ok
        files -> Giulia.Context.Store.put_project_files(project_path, files)
      end

      all_stale = stale ++ new_files

      Logger.info(
        "Cache restore for #{project_path}: #{length(restored)} valid, #{length(stale)} stale, #{length(new_files)} new"
      )

      {:ok, all_stale}
    end
  end

  defp discover_new_files(project_path, cached_entries) do
    cached_paths = MapSet.new(cached_entries, fn {{:ast, path}, _} -> path end)

    lib_path = Path.join(project_path, "lib")

    if File.dir?(lib_path) do
      lib_path
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&Giulia.Context.Indexer.ignored?/1)
      |> Enum.reject(&MapSet.member?(cached_paths, &1))
    else
      []
    end
  end

  defp classify_entries(db, _project_path, cached_entries) do
    Enum.reduce(cached_entries, {[], []}, fn {{:ast, file_path}, ast_data}, {valid, stale} ->
      cond do
        not File.exists?(file_path) ->
          # File deleted from disk
          {valid, [file_path | stale]}

        file_changed?(db, file_path) ->
          # File content changed
          {valid, [file_path | stale]}

        true ->
          # File unchanged — restore to ETS
          {[{file_path, ast_data} | valid], stale}
      end
    end)
  end

  defp file_changed?(db, file_path) do
    stored_hash = CubDB.get(db, {:content_hash, file_path})

    case File.read(file_path) do
      {:ok, content} ->
        current_hash = :crypto.hash(:sha256, content)
        stored_hash != current_hash

      {:error, _} ->
        true
    end
  end
end
