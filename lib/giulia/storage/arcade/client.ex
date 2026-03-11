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
  def create_db do
    url = "#{base_url()}/api/v1/server"
    body = %{command: "create database #{db()}"}
    post(url, body)
  end

  @doc "Ensure all vertex/edge types, properties, and indexes exist. Idempotent."
  def ensure_schema do
    types = [
      "CREATE VERTEX TYPE Module IF NOT EXISTS",
      "CREATE VERTEX TYPE Function IF NOT EXISTS",
      "CREATE VERTEX TYPE File IF NOT EXISTS",
      "CREATE EDGE TYPE DEPENDS_ON IF NOT EXISTS",
      "CREATE EDGE TYPE CALLS IF NOT EXISTS",
      "CREATE EDGE TYPE DEFINED_IN IF NOT EXISTS"
    ]

    properties = [
      {"Module", ["name STRING", "project STRING", "build_id INTEGER", "indexed_at DATETIME"]},
      {"Function", ["name STRING", "project STRING", "build_id INTEGER", "indexed_at DATETIME"]},
      {"File", ["name STRING", "project STRING", "build_id INTEGER", "indexed_at DATETIME"]},
      {"DEPENDS_ON", ["project STRING", "build_id INTEGER"]},
      {"CALLS", ["project STRING", "build_id INTEGER"]},
      {"DEFINED_IN", ["project STRING", "build_id INTEGER"]}
    ]

    # Composite index: same module name can exist in different projects
    indexes = [
      "CREATE INDEX IF NOT EXISTS ON Module (project, name) UNIQUE",
      "CREATE INDEX IF NOT EXISTS ON Function (project, name) UNIQUE",
      "CREATE INDEX IF NOT EXISTS ON File (project, name) UNIQUE"
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
  def command(statement, params \\ %{}) do
    url = "#{base_url()}/api/v1/command/#{db()}"
    body = %{language: "sql", command: statement, params: params}
    post(url, body)
  end

  @doc "Execute a read query (SQL or Cypher). Returns `{:ok, results_list}`."
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
  def cypher(statement, params \\ %{}) do
    query(statement, "cypher", params)
  end

  @doc "Execute a SQL script (multiple statements with LET bindings)."
  def script(statement) do
    url = "#{base_url()}/api/v1/command/#{db()}"
    body = %{language: "sqlscript", command: statement}
    post(url, body)
  end

  # ---------------------------------------------------------------------------
  # Graph write helpers (all project-scoped)
  # ---------------------------------------------------------------------------

  @doc "Upsert a Module vertex. Idempotent per (project, name)."
  def upsert_module(project, name, build_id) do
    command(
      "UPDATE Module SET build_id = :build_id, indexed_at = sysdate() UPSERT WHERE project = :project AND name = :name",
      %{project: project, name: name, build_id: build_id}
    )
  end

  @doc "Upsert a Function vertex. Idempotent per (project, name)."
  def upsert_function(project, name, build_id) do
    command(
      "UPDATE Function SET build_id = :build_id, indexed_at = sysdate() UPSERT WHERE project = :project AND name = :name",
      %{project: project, name: name, build_id: build_id}
    )
  end

  @doc "Create a DEPENDS_ON edge between two modules for a given build."
  def insert_dependency(project, from_module, to_module, build_id) do
    script("""
    LET $a = SELECT FROM Module WHERE project = "#{escape(project)}" AND name = "#{escape(from_module)}";
    LET $b = SELECT FROM Module WHERE project = "#{escape(project)}" AND name = "#{escape(to_module)}";
    CREATE EDGE DEPENDS_ON FROM $a TO $b SET build_id = #{build_id}, project = "#{escape(project)}";
    """)
  end

  @doc "Create a CALLS edge between two functions for a given build."
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
  def impact_map(project, module_name, build_id, depth \\ 3) when is_integer(depth) and depth > 0 do
    cypher("""
    MATCH path = (start:Module {project: $project, name: $name, build_id: $build_id})
                 -[:DEPENDS_ON|CALLS*1..#{depth}]-(affected)
    RETURN DISTINCT affected.name AS name, min(length(path)) AS depth
    ORDER BY depth
    """, %{project: project, name: module_name, build_id: build_id})
  end

  @doc "All builds stored in history for a project, most recent first."
  def list_builds(project) do
    query("""
    SELECT build_id, min(indexed_at) AS first_seen, max(indexed_at) AS last_seen,
           count(*) AS vertex_count
    FROM Module
    WHERE project = :project
    GROUP BY build_id
    ORDER BY build_id DESC
    """, "sql", %{project: project})
  end

  @doc "All projects that have been indexed."
  def list_projects do
    query("SELECT DISTINCT(project) AS project FROM Module ORDER BY project")
  end

  @doc """
  Cross-build dependency diff for a project.

  Returns a list of `%{from, to, change}` where change is "added" or "removed".
  """
  def dependency_diff(project, build_a, build_b) do
    {:ok, removed} = query("""
    SELECT out.name AS `from`, in.name AS `to`, 'removed' AS change
    FROM DEPENDS_ON
    WHERE project = :project AND build_id = :b1
    AND NOT EXISTS (
      SELECT 1 FROM DEPENDS_ON
      WHERE project = :project AND build_id = :b2
      AND out.name = (SELECT name FROM Module WHERE @rid = $parent.out)
      AND in.name  = (SELECT name FROM Module WHERE @rid = $parent.in)
    )
    """, "sql", %{project: project, b1: build_a, b2: build_b})

    {:ok, added} = query("""
    SELECT out.name AS `from`, in.name AS `to`, 'added' AS change
    FROM DEPENDS_ON
    WHERE project = :project AND build_id = :b2
    AND NOT EXISTS (
      SELECT 1 FROM DEPENDS_ON
      WHERE project = :project AND build_id = :b1
      AND out.name = (SELECT name FROM Module WHERE @rid = $parent.out)
      AND in.name  = (SELECT name FROM Module WHERE @rid = $parent.in)
    )
    """, "sql", %{project: project, b1: build_a, b2: build_b})

    {:ok, removed ++ added}
  end

  @doc "Health check — can we reach ArcadeDB?"
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
  def snapshot_graph(project, modules, dependencies, build_id) when is_integer(build_id) do
    module_count =
      Enum.count(modules, fn name ->
        match?({:ok, _}, upsert_module(project, name, build_id))
      end)

    edge_count =
      Enum.count(dependencies, fn {from, to} ->
        match?({:ok, _}, insert_dependency(project, from, to, build_id))
      end)

    Logger.info("ArcadeDB snapshot [#{project}]: #{module_count} modules, #{edge_count} edges (build #{build_id})")
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
            {:ok, _} -> {:cont, :ok}
            {:error, {500, %{"detail" => detail}}} when is_binary(detail) ->
              if String.contains?(detail, "already exists"),
                do: {:cont, :ok},
                else: {:halt, {:error, detail}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end
end
