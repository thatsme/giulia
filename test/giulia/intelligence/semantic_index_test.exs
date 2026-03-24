defmodule Giulia.Intelligence.SemanticIndexTest do
  use ExUnit.Case

  alias Giulia.Intelligence.SemanticIndex

  @fake_project "/nonexistent/project/#{:rand.uniform(100_000)}"

  # ==========================================================================
  # Status — always works, reports availability
  # ==========================================================================

  describe "status/1" do
    test "returns status map for unknown project" do
      result = SemanticIndex.status(@fake_project)
      assert is_map(result)
      assert Map.has_key?(result, :available)
      assert Map.has_key?(result, :module_vectors)
      assert Map.has_key?(result, :function_vectors)
      assert Map.has_key?(result, :model)
      assert Map.has_key?(result, :embedding_in_progress)
    end

    test "reports zero vectors for unembedded project" do
      result = SemanticIndex.status(@fake_project)
      assert result.module_vectors == 0
      assert result.function_vectors == 0
      assert result.embedding_in_progress == false
    end

    test "model name is a string" do
      result = SemanticIndex.status(@fake_project)
      assert is_binary(result.model)
    end
  end

  # ==========================================================================
  # Search — graceful degradation when no embeddings
  # ==========================================================================

  describe "search/3 degradation" do
    test "returns error for project with no embeddings" do
      result = SemanticIndex.search(@fake_project, "authentication", 5)

      case result do
        {:error, msg} ->
          assert is_binary(msg)

        {:ok, _} ->
          # If EmbeddingServing is available but no embeddings, should still error
          flunk("Expected error for project with no embeddings")
      end
    end
  end

  # ==========================================================================
  # available?/0
  # ==========================================================================

  describe "available?/0" do
    test "returns boolean" do
      result = SemanticIndex.available?()
      assert is_boolean(result)
    end
  end

  # ==========================================================================
  # find_duplicates/2 — degradation
  # ==========================================================================

  describe "find_duplicates/2 degradation" do
    test "returns error or empty for project with no embeddings" do
      result = SemanticIndex.find_duplicates(@fake_project)

      case result do
        {:error, msg} ->
          assert is_binary(msg)

        {:ok, %{clusters: clusters}} ->
          # If serving is available, should return empty clusters
          assert clusters == []
      end
    end
  end

  # ==========================================================================
  # embed_project/1 — async, doesn't crash
  # ==========================================================================

  describe "embed_project/1" do
    test "returns :ok without crashing for unknown project" do
      # This is async (cast) — just verify it doesn't crash the GenServer
      assert :ok = SemanticIndex.embed_project(@fake_project)
      # Give it a moment to process the cast
      Process.sleep(100)
      # GenServer should still be alive
      assert Process.whereis(Giulia.Intelligence.SemanticIndex) != nil
    end
  end
end
