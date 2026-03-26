defmodule Giulia.Persistence.Writer do
  @moduledoc """
  Async write-behind GenServer for CubDB persistence.

  Accumulates AST writes in a pending map and flushes to CubDB after a
  100ms debounce window. This batches rapid-fire writes from parallel
  indexing into a single `CubDB.put_multi/2` call per project.

  Also provides direct writes for graph, metrics, and embeddings.
  """
  use GenServer

  require Logger

  @debounce_ms 100

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Queue an AST entry for batched write-behind."
  @spec persist_ast(String.t(), String.t(), map()) :: :ok
  def persist_ast(project_path, file_path, ast_data) do
    content_hash = file_content_hash(file_path)
    GenServer.cast(__MODULE__, {:persist_ast, project_path, file_path, ast_data, content_hash})
  end

  @doc "Delete all cached data for a project."
  @spec clear_project(String.t()) :: :ok
  def clear_project(project_path) do
    GenServer.cast(__MODULE__, {:clear_project, project_path})
  end

  @doc "Persist the serialized knowledge graph."
  @spec persist_graph(String.t(), term()) :: :ok
  def persist_graph(project_path, graph) do
    GenServer.cast(__MODULE__, {:persist_graph, project_path, graph})
  end

  @doc "Persist cached metrics."
  @spec persist_metrics(String.t(), map()) :: :ok
  def persist_metrics(project_path, metrics) do
    GenServer.cast(__MODULE__, {:persist_metrics, project_path, metrics})
  end

  @doc "Persist embedding vectors."
  @spec persist_embeddings(String.t(), atom(), list()) :: :ok
  def persist_embeddings(project_path, type, entries) do
    GenServer.cast(__MODULE__, {:persist_embeddings, project_path, type, entries})
  end

  @doc "Persist project file list."
  @spec persist_project_files(String.t(), [String.t()]) :: :ok
  def persist_project_files(project_path, files) do
    GenServer.cast(__MODULE__, {:persist_project_files, project_path, files})
  end

  @doc "Persist the Merkle tree."
  @spec persist_merkle(String.t(), term()) :: :ok
  def persist_merkle(project_path, tree) do
    GenServer.cast(__MODULE__, {:persist_merkle, project_path, tree})
  end

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    {:ok, %{pending: %{}, timer_ref: nil}}
  end

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast({:persist_ast, project_path, file_path, ast_data, content_hash}, state) do
    # Accumulate in pending map
    project_pending = Map.get(state.pending, project_path, %{})
    project_pending = Map.put(project_pending, file_path, {ast_data, content_hash})
    pending = Map.put(state.pending, project_path, project_pending)

    # Reset debounce timer
    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :flush, @debounce_ms)

    {:noreply, %{state | pending: pending, timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast({:clear_project, project_path}, state) do
    # Remove pending writes for this project
    pending = Map.delete(state.pending, project_path)

    # Clear CubDB
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          # Select all keys and delete them
          keys =
            Enum.map(CubDB.select(db), fn {key, _val} -> key end)

          Enum.each(keys, fn key -> CubDB.delete(db, key) end)
          Logger.info("Cleared CubDB cache for #{project_path}")

        {:error, reason} ->
          Logger.warning("Failed to clear CubDB for #{project_path}: #{inspect(reason)}")
      end
    end)

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:persist_graph, project_path, graph}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          binary = :erlang.term_to_binary(graph, [:compressed])
          CubDB.put(db, {:graph, :serialized}, binary)
          Logger.debug("Persisted knowledge graph for #{project_path} (#{byte_size(binary)} bytes)")

        {:error, reason} ->
          Logger.warning("Failed to persist graph: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:persist_metrics, project_path, metrics}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          CubDB.put(db, {:metrics, :cached}, metrics)
          Logger.debug("Persisted metrics cache for #{project_path}")

        {:error, reason} ->
          Logger.warning("Failed to persist metrics: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:persist_embeddings, project_path, type, entries}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          CubDB.put(db, {:embedding, type}, entries)
          Logger.debug("Persisted #{type} embeddings for #{project_path} (#{length(entries)} entries)")

        {:error, reason} ->
          Logger.warning("Failed to persist embeddings: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:persist_project_files, project_path, files}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          CubDB.put(db, {:project_files}, files)
          Logger.debug("Persisted project file list for #{project_path} (#{length(files)} files)")

        {:error, reason} ->
          Logger.warning("Failed to persist project files: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:persist_merkle, project_path, tree}, state) do
    Task.Supervisor.start_child(Giulia.TaskSupervisor, fn ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          CubDB.put(db, {:merkle, :tree}, tree)
          Logger.debug("Persisted Merkle tree for #{project_path}")

        {:error, reason} ->
          Logger.warning("Failed to persist Merkle tree: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info(:flush, state) do
    flush_pending(state.pending)
    {:noreply, %{state | pending: %{}, timer_ref: nil}}
  end

  # Private

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp flush_pending(pending) when map_size(pending) == 0, do: :ok

  defp flush_pending(pending) do
    Enum.each(pending, fn {project_path, file_map} ->
      case Giulia.Persistence.Store.get_db(project_path) do
        {:ok, db} ->
          # Build batch: AST entries + content hashes
          entries =
            Enum.flat_map(file_map, fn {file_path, {ast_data, content_hash}} ->
              [
                {{:ast, file_path}, ast_data},
                {{:content_hash, file_path}, content_hash}
              ]
            end)

          # Add metadata
          schema_version = Giulia.Persistence.Store.schema_version()
          build = Giulia.Persistence.Store.current_build()

          entries =
            entries ++
              [
                {{:meta, :schema_version}, schema_version},
                {{:meta, :build}, build},
                {{:meta, :last_scan}, DateTime.utc_now()}
              ]

          CubDB.put_multi(db, entries)

          # Update Merkle tree with new leaves
          update_merkle_tree(db, project_path, file_map)

          file_count = map_size(file_map)
          Logger.info("Flushed #{file_count} AST entries to CubDB for #{project_path}")

        {:error, reason} ->
          Logger.warning("Failed to flush to CubDB for #{project_path}: #{inspect(reason)}")
      end
    end)
  end

  defp update_merkle_tree(db, project_path, file_map) do
    # Load existing tree or build fresh
    existing_tree = CubDB.get(db, {:merkle, :tree})

    tree =
      if existing_tree do
        # Update each changed leaf
        Enum.reduce(file_map, existing_tree, fn {file_path, {ast_data, _hash}}, tree ->
          Giulia.Persistence.Merkle.update_leaf(tree, file_path, ast_data)
        end)
      else
        # Build fresh from all cached ASTs
        all_asts =
          Enum.map(CubDB.select(db, min_key: {:ast, ""}, max_key: {:ast, <<255>>}), fn {{:ast, path}, data} -> {path, data} end)

        Giulia.Persistence.Merkle.build(all_asts)
      end

    CubDB.put(db, {:merkle, :tree}, tree)
    Giulia.Persistence.Writer.persist_merkle(project_path, tree)
  rescue
    e ->
      Logger.warning("Merkle tree update failed: #{Exception.message(e)}")
  end

  defp file_content_hash(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, _} -> nil
    end
  end
end
