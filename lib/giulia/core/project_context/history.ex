defmodule Giulia.Core.ProjectContext.History do
  @moduledoc """
  SQLite-backed conversation history for a project.

  Manages the `.giulia/history/chat.db` database: opening, creating tables,
  inserting messages, fetching recent history, and cleanup on shutdown.

  All functions accept the SQLite connection reference (or nil for graceful no-ops).

  Extracted from `Core.ProjectContext` (Build 128).
  """

  require Logger

  @spec init(String.t()) :: reference() | nil
  def init(project_path) do
    db_path = Path.join([project_path, ".giulia", "history", "chat.db"])

    db_path |> Path.dirname() |> File.mkdir_p()

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        create_table(conn)
        conn

      {:error, reason} ->
        Logger.error("Failed to open history DB: #{inspect(reason)}")
        nil
    end
  end

  @spec insert(reference() | nil, String.t(), String.t()) :: :ok
  def insert(nil, _role, _content), do: :ok

  def insert(conn, role, content) do
    sql = "INSERT INTO messages (role, content) VALUES (?1, ?2)"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [role, content])
        Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)

      {:error, reason} ->
        Logger.error("Failed to insert history: #{inspect(reason)}")
    end
  end

  @spec fetch(reference() | nil, non_neg_integer()) :: [map()]
  def fetch(nil, _limit), do: []

  def fetch(conn, limit) do
    sql = "SELECT role, content, created_at FROM messages ORDER BY id DESC LIMIT ?1"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [limit])
        results = fetch_all_rows(conn, stmt, [])
        Exqlite.Sqlite3.release(conn, stmt)
        Enum.reverse(results)

      {:error, _} ->
        []
    end
  end

  @spec close(reference() | nil) :: :ok
  def close(nil), do: :ok

  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp create_table(nil), do: :ok

  defp create_table(conn) do
    sql = """
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
    """

    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Failed to create history table: #{inspect(reason)}")
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [role, content, created_at]} ->
        row = %{role: role, content: content, created_at: created_at}
        fetch_all_rows(conn, stmt, [row | acc])

      :done ->
        acc
    end
  end
end
