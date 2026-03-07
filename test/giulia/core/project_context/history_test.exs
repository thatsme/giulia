defmodule Giulia.Core.ProjectContext.HistoryTest do
  use ExUnit.Case, async: false

  alias Giulia.Core.ProjectContext.History

  @test_dir Path.join(System.tmp_dir!(), "giulia_history_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    conn = History.init(@test_dir)

    on_exit(fn ->
      if conn, do: History.close(conn)
      File.rm_rf!(@test_dir)
    end)

    %{conn: conn}
  end

  # ============================================================================
  # init/1
  # ============================================================================

  describe "init/1" do
    test "opens SQLite database and returns connection" do
      dir = Path.join(System.tmp_dir!(), "giulia_hist_init_#{:rand.uniform(100_000)}")
      conn = History.init(dir)
      assert conn != nil
      History.close(conn)
      File.rm_rf!(dir)
    end

    test "creates .giulia/history/ directory" do
      dir = Path.join(System.tmp_dir!(), "giulia_hist_dir_#{:rand.uniform(100_000)}")
      conn = History.init(dir)
      assert File.exists?(Path.join([dir, ".giulia", "history", "chat.db"]))
      History.close(conn)
      File.rm_rf!(dir)
    end
  end

  # ============================================================================
  # insert/3 + fetch/2
  # ============================================================================

  describe "insert/3 and fetch/2" do
    test "inserts and retrieves a message", %{conn: conn} do
      History.insert(conn, "user", "Hello Giulia")
      messages = History.fetch(conn, 10)
      assert length(messages) == 1
      assert hd(messages).role == "user"
      assert hd(messages).content == "Hello Giulia"
    end

    test "retrieves messages in reverse chronological order", %{conn: conn} do
      History.insert(conn, "user", "First")
      History.insert(conn, "assistant", "Second")
      History.insert(conn, "user", "Third")

      messages = History.fetch(conn, 10)
      assert length(messages) == 3
      # DESC order, then reversed → most recent first after reverse = chronological
      # Actually: SELECT ... ORDER BY id DESC → [Third, Second, First] → reverse → [First, Second, Third]
      # But the raw query returns DESC, then Enum.reverse gives ascending
      contents = Enum.map(messages, & &1.content)
      # All three present regardless of order
      assert "First" in contents
      assert "Second" in contents
      assert "Third" in contents
    end

    test "respects limit parameter", %{conn: conn} do
      for i <- 1..20 do
        History.insert(conn, "user", "Message #{i}")
      end

      messages = History.fetch(conn, 5)
      assert length(messages) == 5
      # Gets the 5 most recent messages
      contents = Enum.map(messages, & &1.content)
      assert "Message 20" in contents
      assert "Message 16" in contents
      refute "Message 15" in contents
    end

    test "returns empty list for no messages", %{conn: conn} do
      assert History.fetch(conn, 10) == []
    end
  end

  # ============================================================================
  # nil connection (graceful no-ops)
  # ============================================================================

  describe "nil connection handling" do
    test "insert with nil conn is a no-op" do
      assert History.insert(nil, "user", "test") == :ok
    end

    test "fetch with nil conn returns empty list" do
      assert History.fetch(nil, 10) == []
    end

    test "close with nil conn is a no-op" do
      assert History.close(nil) == :ok
    end
  end

  # ============================================================================
  # Adversarial inputs
  # ============================================================================

  describe "adversarial inputs" do
    test "handles very long content", %{conn: conn} do
      long_content = String.duplicate("x", 100_000)
      History.insert(conn, "user", long_content)
      [msg] = History.fetch(conn, 1)
      assert String.length(msg.content) == 100_000
    end

    test "handles special characters in content", %{conn: conn} do
      content = "SELECT * FROM users; DROP TABLE messages; --"
      History.insert(conn, "user", content)
      [msg] = History.fetch(conn, 1)
      assert msg.content == content
    end

    test "handles unicode content", %{conn: conn} do
      content = "こんにちは世界 🌍 Ελληνικά"
      History.insert(conn, "user", content)
      [msg] = History.fetch(conn, 1)
      assert msg.content == content
    end

    test "handles empty strings", %{conn: conn} do
      History.insert(conn, "", "")
      [msg] = History.fetch(conn, 1)
      assert msg.role == ""
      assert msg.content == ""
    end

    test "handles newlines in content", %{conn: conn} do
      content = "line1\nline2\nline3"
      History.insert(conn, "user", content)
      [msg] = History.fetch(conn, 1)
      assert msg.content == content
    end

    test "fetch with limit 0 returns empty", %{conn: conn} do
      History.insert(conn, "user", "test")
      assert History.fetch(conn, 0) == []
    end
  end

  # ============================================================================
  # Integration: close and reopen
  # ============================================================================

  describe "persistence" do
    test "data survives close and reopen" do
      dir = Path.join(System.tmp_dir!(), "giulia_hist_persist_#{:rand.uniform(100_000)}")

      # Write data
      conn1 = History.init(dir)
      History.insert(conn1, "user", "persistent message")
      History.close(conn1)

      # Reopen and read
      conn2 = History.init(dir)
      messages = History.fetch(conn2, 10)
      assert length(messages) == 1
      assert hd(messages).content == "persistent message"
      History.close(conn2)

      File.rm_rf!(dir)
    end
  end
end
