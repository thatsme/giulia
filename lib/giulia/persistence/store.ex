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
  # v5: function_info gains :min_arity — tracks default-arg arities for graph.
  # v6: mix.exs included in scan + references pass for framework wiring.
  # v7: :calls edges carry {:calls, via} label with resolution-path metadata.
  # v8: GRAPH-COMPLETENESS FIX (commits 7792107 / 6da8764 / 9d5cb1e).
  #     Three AST walkers (Extraction, Metrics.collect_all_calls,
  #     Builder.add_function_call_edges) had the same "first-module-wins"
  #     bug for multi-defmodule files + single-segment-only alias
  #     resolution. Fixed with Macro.traverse + module-stack and
  #     resolve_alias_prefix. Quantified impact on a real-world 466-file
  #     Phoenix codebase used as the canonical measurement target:
  #     +319 call edges (+5.6%), −176 components,
  #     −66 dead_code false positives. Top change_risk / heatmap / SCC
  #     findings unchanged (bug was in bridge edges, not hub-of-hubs
  #     edges), but pre_impact_check and tail-rank analyses were
  #     undercounted. Bumping v8 forces cold rescan on next load —
  #     cached graphs from v7 are known-incomplete.
  # `module_info` gains :impl_for (commit 11ccbd3) for protocol-dispatch
  # edge synthesis; `function_info` gains :module (commit 7792107).
  # Cached AST data shape is compatible with v7 via fallbacks in
  # Builder/Query, but cached graphs are not — force the bump.
  @schema_version 8

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

  @doc """
  Verify the persisted Merkle tree for a project. Returns one of three
  documented payload shapes:

    * `%{status: "no_cache", verified: false}` — DB missing or no Merkle
      tree persisted yet.
    * `%{status: "ok", verified: true, root: <hex12>, leaf_count: N}` —
      tree verifies clean.
    * `%{status: "corrupted", verified: false, leaf_count: N}` — tree
      structure detects mismatch.

  Single source of truth for both the HTTP `POST /api/index/verify`
  endpoint and the MCP `index_verify` tool.
  """
  @spec verify_cache(String.t()) :: {:ok, map()}
  def verify_cache(project_path) do
    case get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:merkle, :tree}) do
          nil ->
            {:ok, %{status: "no_cache", verified: false}}

          tree ->
            case Giulia.Persistence.Merkle.verify(tree) do
              :ok ->
                root_hex =
                  tree
                  |> Giulia.Persistence.Merkle.root_hash()
                  |> Base.encode16(case: :lower)
                  |> String.slice(0, 12)

                {:ok,
                 %{
                   status: "ok",
                   verified: true,
                   root: root_hex,
                   leaf_count: tree.leaf_count
                 }}

              {:error, :corrupted} ->
                {:ok, %{status: "corrupted", verified: false, leaf_count: tree.leaf_count}}
            end
        end

      {:error, _} ->
        {:ok, %{status: "no_cache", verified: false}}
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
