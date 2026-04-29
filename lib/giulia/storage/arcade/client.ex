defmodule Giulia.Storage.Arcade.Client do
  @moduledoc """
  HTTP client for ArcadeDB REST API.

  L2 storage — persistence, history, consolidation queries.
  Not on the hot path. ETS + libgraph remain L1 for real-time queries.

  All writes are scoped by `project` (path string) so multiple projects
  coexist in the same database without collision.

  ## Configuration

      config :giulia,
        arcadedb_url: "http://arcadedb:2480",
        arcadedb_db: "giulia",
        arcadedb_user: "root",
        arcadedb_password: "playwithdata"
  """

  require Logger

  @default_url "http://localhost:2480"
  @default_db "giulia"
  @default_user "root"
  @default_password "playwithdata"
  @default_timeout 5_000

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp base_url, do: Application.get_env(:giulia, :arcadedb_url, @default_url)
  defp db, do: Application.get_env(:giulia, :arcadedb_db, @default_db)
  defp user, do: Application.get_env(:giulia, :arcadedb_user, @default_user)
  defp password, do: Application.get_env(:giulia, :arcadedb_password, @default_password)

  # ---------------------------------------------------------------------------
  # Database lifecycle
  # ---------------------------------------------------------------------------

  @doc "Create the database if it doesn't exist."
  @spec create_db() :: :ok | {:error, term()}
  def create_db do
    url = "#{base_url()}/api/v1/server"
    body = %{command: "create database #{db()}"}

    case Req.post(url,
           json: body,
           auth: {:basic, "#{user()}:#{password()}"},
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200}} ->
        :ok

      # Already exists — not an error. ArcadeDB returns 400 in current
      # versions and 500 in older ones; match on the detail string rather
      # than the status code so we survive future server-side changes.
      {:ok, %{status: status, body: %{"detail" => detail}}}
      when status in [400, 500] and is_binary(detail) ->
        if String.contains?(detail, "already exists"),
          do: :ok,
          else: {:error, {status, detail}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Ensure all vertex/edge types, properties, and indexes exist. Idempotent."
  @spec ensure_schema() :: :ok | {:error, term()}
  def ensure_schema do
    types = [
      "CREATE VERTEX TYPE Module IF NOT EXISTS",
      "CREATE VERTEX TYPE Function IF NOT EXISTS",
      "CREATE VERTEX TYPE File IF NOT EXISTS",
      "CREATE VERTEX TYPE Insight IF NOT EXISTS",
      "CREATE EDGE TYPE DEPENDS_ON IF NOT EXISTS",
      "CREATE EDGE TYPE CALLS IF NOT EXISTS",
      "CREATE EDGE TYPE DEFINED_IN IF NOT EXISTS"
    ]

    properties = [
      {"Module",
       [
         "name STRING",
         "project STRING",
         "build_id INTEGER",
         "indexed_at DATETIME",
         "function_count INTEGER",
         "complexity_score INTEGER",
         "dep_in INTEGER",
         "dep_out INTEGER"
       ]},
      {"Function",
       [
         "name STRING",
         "project STRING",
         "build_id INTEGER",
         "indexed_at DATETIME",
         "complexity INTEGER"
       ]},
      {"File", ["name STRING", "project STRING", "build_id INTEGER", "indexed_at DATETIME"]},
      {"Insight",
       [
         "type STRING",
         "module STRING",
         "project STRING",
         "build_id INTEGER",
         "severity STRING",
         "trend STRING",
         "detected_at DATETIME",
         "build_range_start INTEGER",
         "build_range_end INTEGER"
       ]},
      {"DEPENDS_ON", ["project STRING", "build_id INTEGER"]},
      {"CALLS", ["project STRING", "build_id INTEGER"]},
      {"DEFINED_IN", ["project STRING", "build_id INTEGER"]}
    ]

    # Composite index: same module name can exist in different projects
    indexes = [
      "CREATE INDEX IF NOT EXISTS ON Module (project, name) UNIQUE",
      "CREATE INDEX IF NOT EXISTS ON Function (project, name) UNIQUE",
      "CREATE INDEX IF NOT EXISTS ON File (project, name) UNIQUE",
      "CREATE INDEX IF NOT EXISTS ON Insight (project, type, module) UNIQUE"
    ]

    with :ok <- run_statements(types),
         :ok <- ensure_properties(properties),
         :ok <- run_statements(indexes) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Core API
  # ---------------------------------------------------------------------------

  @doc "Execute a SQL command (INSERT, CREATE, UPDATE, DELETE)."
  @spec command(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def command(statement, params \\ %{}) do
    url = "#{base_url()}/api/v1/command/#{db()}"
    body = %{language: "sql", command: statement, params: params}
    post(url, body)
  end

  @doc "Execute a read query (SQL or Cypher). Returns `{:ok, results_list}`."
  @spec query(String.t(), String.t(), map()) :: {:ok, list()} | {:error, term()}
  def query(statement, language \\ "sql", params \\ %{}) do
    url = "#{base_url()}/api/v1/command/#{db()}"
    body = %{language: language, command: statement, params: params}

    case post(url, body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, other} -> {:ok, other}
      error -> error
    end
  end

  @doc "Execute a Cypher query. Returns `{:ok, results_list}`."
  @spec cypher(String.t(), map()) :: {:ok, list()} | {:error, term()}
  def cypher(statement, params \\ %{}) do
    query(statement, "cypher", params)
  end

  @doc "Execute a SQL script (multiple statements with LET bindings)."
  @spec script(String.t()) :: {:ok, term()} | {:error, term()}
  def script(statement) do
    url = "#{base_url()}/api/v1/command/#{db()}"
    body = %{language: "sqlscript", command: statement}
    post(url, body)
  end

  # ---------------------------------------------------------------------------
  # Graph write helpers (all project-scoped)
  # ---------------------------------------------------------------------------

  @doc "Upsert a Module vertex. Idempotent per (project, name)."
  @spec upsert_module(String.t(), String.t(), integer(), map()) ::
          {:ok, term()} | {:error, term()}
  def upsert_module(project, name, build_id, metrics \\ %{}) do
    fc = Map.get(metrics, :function_count, 0)
    cs = Map.get(metrics, :complexity_score, 0)
    di = Map.get(metrics, :dep_in, 0)
    do_ = Map.get(metrics, :dep_out, 0)

    command(
      """
      UPDATE Module SET build_id = :build_id, indexed_at = sysdate(),
        function_count = :fc, complexity_score = :cs, dep_in = :di, dep_out = :do
      UPSERT WHERE project = :project AND name = :name
      """,
      %{project: project, name: name, build_id: build_id, fc: fc, cs: cs, di: di, do: do_}
    )
  end

  @doc "Upsert a Function vertex. Idempotent per (project, name)."
  @spec upsert_function(String.t(), String.t(), integer(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def upsert_function(project, name, build_id, complexity \\ 0) do
    command(
      """
      UPDATE Function SET build_id = :build_id, indexed_at = sysdate(), complexity = :complexity
      UPSERT WHERE project = :project AND name = :name
      """,
      %{project: project, name: name, build_id: build_id, complexity: complexity}
    )
  end

  @doc "Upsert an Insight vertex. Idempotent per (project, type, module)."
  @spec upsert_insight(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          integer(),
          String.t(),
          integer(),
          integer()
        ) ::
          {:ok, term()} | {:error, term()}
  def upsert_insight(
        project,
        type,
        module,
        severity,
        build_id,
        trend,
        build_range_start,
        build_range_end
      ) do
    command(
      """
      UPDATE Insight SET build_id = :build_id, severity = :severity, trend = :trend,
        build_range_start = :brs, build_range_end = :bre, detected_at = sysdate()
      UPSERT WHERE project = :project AND type = :type AND module = :module
      """,
      %{
        project: project,
        type: type,
        module: module,
        severity: severity,
        build_id: build_id,
        trend: trend,
        brs: build_range_start,
        bre: build_range_end
      }
    )
  end

  @doc "List insights for a project, optionally filtered by build_id."
  @spec list_insights(String.t(), integer() | nil) :: {:ok, list()} | {:error, term()}
  def list_insights(project, build_id \\ nil) do
    if build_id do
      query("SELECT FROM Insight WHERE project = :p AND build_id = :b", "sql", %{
        p: project,
        b: build_id
      })
    else
      query("SELECT FROM Insight WHERE project = :p", "sql", %{p: project})
    end
  end

  @doc "Return modules ranked by hotspot score for a given build."
  @spec hotspots(String.t(), integer(), non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def hotspots(project, build_id, limit \\ 10) do
    query(
      """
        SELECT name, complexity_score, dep_in, dep_out, function_count,
          (complexity_score + dep_in + dep_out) AS hotspot_score
        FROM Module
        WHERE project = :p AND build_id = :b
          AND (complexity_score > 0 OR dep_in > 0 OR dep_out > 0)
        ORDER BY hotspot_score DESC
        LIMIT #{limit}
      """,
      "sql",
      %{p: project, b: build_id}
    )
  end

  @doc "Return complexity history across builds for a project."
  @spec complexity_history(String.t(), non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def complexity_history(project, limit \\ 10) do
    query(
      """
        SELECT name, build_id, complexity_score
        FROM Module
        WHERE project = :p AND complexity_score > 0
        ORDER BY name, build_id
        LIMIT #{limit * 50}
      """,
      "sql",
      %{p: project}
    )
  end

  @doc "Return coupling history across builds for a project."
  @spec coupling_history(String.t(), non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def coupling_history(project, limit \\ 10) do
    query(
      """
        SELECT name, build_id, dep_in, dep_out
        FROM Module
        WHERE project = :p AND (dep_in > 0 OR dep_out > 0)
        ORDER BY name, build_id
        LIMIT #{limit * 50}
      """,
      "sql",
      %{p: project}
    )
  end

  @doc """
  Delete all edges of `edge_type` scoped to `(project, build_id)`.

  `CREATE EDGE` is not idempotent in ArcadeDB — re-running a snapshot
  under the same build_id appends duplicate edges. Callers invoke this
  before re-inserting so each (project, build_id) has one authoritative
  edge set. Cross-build history is preserved because the delete is
  filtered by build_id.
  """
  @spec delete_edges_for_build(String.t(), String.t(), integer()) ::
          {:ok, term()} | {:error, term()}
  def delete_edges_for_build(edge_type, project, build_id)
      when edge_type in ["CALLS", "DEPENDS_ON"] do
    command(
      "DELETE FROM #{edge_type} WHERE project = :project AND build_id = :build_id",
      %{project: project, build_id: build_id}
    )
  end

  @doc """
  Delete edges of `edge_type` scoped to `project` whose `build_id` is
  strictly less than `keep_from`. Used by the Consolidator's retention
  pruning — preserves the most recent N builds while shedding the
  long tail that accumulates across rescans (each scan re-snapshots
  the current build's edges idempotently, but prior builds' edges are
  NOT removed by `delete_edges_for_build/3`, which is build-id-scoped).
  """
  @spec delete_edges_older_than(String.t(), String.t(), integer()) ::
          {:ok, term()} | {:error, term()}
  def delete_edges_older_than(edge_type, project, keep_from)
      when edge_type in ["CALLS", "DEPENDS_ON"] and is_integer(keep_from) do
    command(
      "DELETE FROM #{edge_type} WHERE project = :project AND build_id < :keep_from",
      %{project: project, keep_from: keep_from}
    )
  end

  @doc "Create a DEPENDS_ON edge between two modules for a given build."
  @spec insert_dependency(String.t(), String.t(), String.t(), integer()) ::
          {:ok, term()} | {:error, term()}
  def insert_dependency(project, from_module, to_module, build_id) do
    script("""
    LET $a = SELECT FROM Module WHERE project = "#{escape(project)}" AND name = "#{escape(from_module)}";
    LET $b = SELECT FROM Module WHERE project = "#{escape(project)}" AND name = "#{escape(to_module)}";
    CREATE EDGE DEPENDS_ON FROM $a TO $b SET build_id = #{build_id}, project = "#{escape(project)}";
    """)
  end

  @doc "Create a CALLS edge between two functions for a given build."
  @spec insert_call(String.t(), String.t(), String.t(), integer()) ::
          {:ok, term()} | {:error, term()}
  def insert_call(project, from_function, to_function, build_id) do
    script("""
    LET $a = SELECT FROM Function WHERE project = "#{escape(project)}" AND name = "#{escape(from_function)}";
    LET $b = SELECT FROM Function WHERE project = "#{escape(project)}" AND name = "#{escape(to_function)}";
    CREATE EDGE CALLS FROM $a TO $b SET build_id = #{build_id}, project = "#{escape(project)}";
    """)
  end

  # ---------------------------------------------------------------------------
  # Graph read helpers
  # ---------------------------------------------------------------------------

  @doc """
  Full blast radius — bidirectional, depth-limited traversal.

  Returns all modules reachable within `depth` hops via DEPENDS_ON or CALLS
  edges in either direction. One Cypher query does what requires two recursive
  functions in libgraph (upstream + downstream).
  """
  @spec impact_map(String.t(), String.t(), integer(), pos_integer()) ::
          {:ok, list()} | {:error, term()}
  def impact_map(project, module_name, build_id, depth \\ 3)
      when is_integer(depth) and depth > 0 do
    cypher(
      """
      MATCH path = (start:Module {project: $project, name: $name, build_id: $build_id})
                   -[:DEPENDS_ON|CALLS*1..#{depth}]-(affected)
      RETURN DISTINCT affected.name AS name, min(length(path)) AS depth
      ORDER BY depth
      """,
      %{project: project, name: module_name, build_id: build_id}
    )
  end

  @doc "All builds stored in history for a project, most recent first."
  @spec list_builds(String.t()) :: {:ok, list()} | {:error, term()}
  def list_builds(project) do
    query(
      """
      SELECT build_id, min(indexed_at) AS first_seen, max(indexed_at) AS last_seen,
             count(*) AS vertex_count
      FROM Module
      WHERE project = :project
      GROUP BY build_id
      ORDER BY build_id DESC
      """,
      "sql",
      %{project: project}
    )
  end

  @doc "All projects that have been indexed."
  @spec list_projects() :: {:ok, list()} | {:error, term()}
  def list_projects do
    query("SELECT DISTINCT(project) AS project FROM Module ORDER BY project")
  end

  @doc """
  Cross-build dependency diff for a project.

  Returns a list of `%{from, to, change}` where change is "added" or "removed".
  """
  @spec dependency_diff(String.t(), integer(), integer()) :: {:ok, list()} | {:error, term()}
  def dependency_diff(project, build_a, build_b) do
    {:ok, removed} =
      query(
        """
        SELECT out.name AS `from`, in.name AS `to`, 'removed' AS change
        FROM DEPENDS_ON
        WHERE project = :project AND build_id = :b1
        AND NOT EXISTS (
          SELECT 1 FROM DEPENDS_ON
          WHERE project = :project AND build_id = :b2
          AND out.name = (SELECT name FROM Module WHERE @rid = $parent.out)
          AND in.name  = (SELECT name FROM Module WHERE @rid = $parent.in)
        )
        """,
        "sql",
        %{project: project, b1: build_a, b2: build_b}
      )

    {:ok, added} =
      query(
        """
        SELECT out.name AS `from`, in.name AS `to`, 'added' AS change
        FROM DEPENDS_ON
        WHERE project = :project AND build_id = :b2
        AND NOT EXISTS (
          SELECT 1 FROM DEPENDS_ON
          WHERE project = :project AND build_id = :b1
          AND out.name = (SELECT name FROM Module WHERE @rid = $parent.out)
          AND in.name  = (SELECT name FROM Module WHERE @rid = $parent.in)
        )
        """,
        "sql",
        %{project: project, b1: build_a, b2: build_b}
      )

    {:ok, removed ++ added}
  end

  @doc "Health check — can we reach ArcadeDB?"
  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    url = "#{base_url()}/api/v1/server"

    case Req.get(url, auth: {:basic, "#{user()}:#{password()}"}, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{version: body["version"], databases: body["totalDatabases"]}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Batch operations
  # ---------------------------------------------------------------------------

  @doc """
  Snapshot a full graph into ArcadeDB for a given project and build_id.

  Accepts:
  - `project` — project path string
  - `modules` — list of module name strings
  - `dependencies` — list of `{from, to}` tuples
  - `build_id` — integer build number

  Returns `{:ok, %{modules: n, edges: n}}`.
  """
  @spec snapshot_graph(String.t(), list(), list(), integer()) :: {:ok, map()} | {:error, term()}
  def snapshot_graph(project, modules, dependencies, build_id) when is_integer(build_id) do
    module_count =
      Enum.count(modules, fn name ->
        match?({:ok, _}, upsert_module(project, name, build_id))
      end)

    edge_count =
      Enum.count(dependencies, fn {from, to} ->
        match?({:ok, _}, insert_dependency(project, from, to, build_id))
      end)

    Logger.info(
      "ArcadeDB snapshot [#{project}]: #{module_count} modules, #{edge_count} edges (build #{build_id})"
    )

    {:ok, %{modules: module_count, edges: edge_count}}
  end

  # ---------------------------------------------------------------------------
  # HTTP plumbing (Req)
  # ---------------------------------------------------------------------------

  defp post(url, body) do
    case Req.post(url,
           json: body,
           auth: {:basic, "#{user()}:#{password()}"},
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        detail = if is_map(body), do: body["detail"] || body["error"], else: inspect(body)
        Logger.debug("ArcadeDB #{status}: #{detail}")
        {:error, {status, body}}

      {:error, %{reason: reason}} ->
        Logger.error("ArcadeDB unreachable: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("ArcadeDB request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp escape(value) when is_binary(value) do
    String.replace(value, "\"", "\\\"")
  end

  defp run_statements(statements) do
    Enum.reduce_while(statements, :ok, fn stmt, _acc ->
      case command(stmt) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp ensure_properties(type_props) do
    Enum.reduce_while(type_props, :ok, fn {type, props}, _acc ->
      result =
        Enum.reduce_while(props, :ok, fn prop, _inner ->
          case command("CREATE PROPERTY #{type}.#{prop}") do
            {:ok, _} ->
              {:cont, :ok}

            {:error, {500, %{"detail" => detail}}} when is_binary(detail) ->
              if String.contains?(detail, "already exists"),
                do: {:cont, :ok},
                else: {:halt, {:error, detail}}

            {:error, _} = err ->
              {:halt, err}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end
end
