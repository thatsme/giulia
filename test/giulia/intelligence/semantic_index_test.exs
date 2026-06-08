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

  # ==========================================================================
  # extract_similar_pairs/4 — vectorized impl must equal the original loop
  # ==========================================================================

  describe "extract_similar_pairs/4 (vectorized)" do
    # Reference: the ORIGINAL per-cell loop, kept here as the equivalence oracle.
    # The production impl was vectorized for O(n^2) perf; this proves the swap is
    # pair-for-pair identical rather than trusting the Nx idiom.
    defp reference_loop(matrix, n, threshold) do
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1), reduce: [] do
        acc ->
          score = Nx.to_number(matrix[i][j])
          if score >= threshold, do: [{i, j, Float.round(score, 4)} | acc], else: acc
      end
    end

    test "produces identical pairs to the loop (incl. the exact-threshold boundary)" do
      # (0,2)=0.85 sits EXACTLY on the threshold — included by `>=`, dropped by a
      # strict `>`. (2,3)=0.84 is just below. Diagonal + lower triangle excluded.
      matrix =
        Nx.tensor(
          [
            [1.0, 0.90, 0.85, 0.40],
            [0.90, 1.0, 0.20, 0.86],
            [0.85, 0.20, 1.0, 0.84],
            [0.40, 0.86, 0.84, 1.0]
          ],
          type: :f32
        )

      threshold = 0.85
      expected = reference_loop(matrix, 4, threshold) |> Enum.sort()
      actual = SemanticIndex.extract_similar_pairs(matrix, nil, 4, threshold) |> Enum.sort()

      assert actual == expected
      # guard the boundary explicitly: (0,2) at exactly 0.85 must be present
      assert Enum.any?(actual, fn {i, j, _} -> i == 0 and j == 2 end)
    end

    test "empty when nothing meets the threshold" do
      matrix = Nx.tensor([[1.0, 0.1, 0.2], [0.1, 1.0, 0.3], [0.2, 0.3, 1.0]], type: :f32)
      assert SemanticIndex.extract_similar_pairs(matrix, nil, 3, 0.85) == []
    end
  end
end
