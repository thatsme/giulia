defmodule Giulia.Persistence.MerkleAdversarialTest do
  @moduledoc """
  Adversarial tests for Persistence.Merkle (pure Merkle tree).

  Targets:
  - Odd number of leaves (self-hash promotion)
  - Large trees (1000+ leaves)
  - Duplicate file paths
  - Tampered internal nodes (not just leaves)
  - Update → verify consistency
  - Remove nonexistent leaf
  - Diff between empty and populated trees
  - ETF determinism (same data → same hash across calls)
  - Unicode file paths
  - Deeply nested path names
  """
  use ExUnit.Case, async: true

  alias Giulia.Persistence.Merkle

  # ============================================================================
  # Odd leaf count (self-hash promotion)
  # ============================================================================

  describe "odd leaf count" do
    test "3 leaves: one node gets self-hashed" do
      tree = Merkle.build([
        {"a.ex", %{x: 1}},
        {"b.ex", %{x: 2}},
        {"c.ex", %{x: 3}}
      ])

      assert tree.leaf_count == 3
      assert Merkle.verify(tree) == :ok
    end

    test "5 leaves" do
      pairs = for i <- 1..5, do: {"file_#{i}.ex", %{x: i}}
      tree = Merkle.build(pairs)
      assert tree.leaf_count == 5
      assert Merkle.verify(tree) == :ok
    end

    test "7 leaves" do
      pairs = for i <- 1..7, do: {"file_#{i}.ex", %{x: i}}
      tree = Merkle.build(pairs)
      assert tree.leaf_count == 7
      assert Merkle.verify(tree) == :ok
    end

    test "1 leaf" do
      tree = Merkle.build([{"solo.ex", %{x: 1}}])
      assert tree.leaf_count == 1
      assert Merkle.verify(tree) == :ok
    end
  end

  # ============================================================================
  # Large trees
  # ============================================================================

  describe "large trees" do
    test "1000 leaves build and verify" do
      pairs = for i <- 1..1000, do: {"lib/mod_#{i}.ex", %{module: "Mod#{i}", line: i}}
      tree = Merkle.build(pairs)

      assert tree.leaf_count == 1000
      assert Merkle.verify(tree) == :ok
      assert is_binary(Merkle.root_hash(tree))
    end

    test "1000 leaves: update one leaf changes root" do
      pairs = for i <- 1..1000, do: {"lib/mod_#{i}.ex", %{module: "Mod#{i}", line: i}}
      tree = Merkle.build(pairs)
      original_root = Merkle.root_hash(tree)

      updated = Merkle.update_leaf(tree, "lib/mod_500.ex", %{module: "Mod500", line: 999})
      assert Merkle.root_hash(updated) != original_root
      assert Merkle.verify(updated) == :ok
    end

    test "1000 leaves: diff detects single change" do
      pairs = for i <- 1..1000, do: {"lib/mod_#{i}.ex", %{module: "Mod#{i}", line: i}}
      tree_a = Merkle.build(pairs)

      modified_pairs =
        Enum.map(pairs, fn
          {"lib/mod_500.ex", _} -> {"lib/mod_500.ex", %{module: "Mod500", line: 999}}
          other -> other
        end)

      tree_b = Merkle.build(modified_pairs)

      diff = Merkle.diff(tree_a, tree_b)
      assert diff == ["lib/mod_500.ex"]
    end
  end

  # ============================================================================
  # Duplicate file paths
  # ============================================================================

  describe "duplicate file paths" do
    test "duplicate paths in build — last value wins (Map.new)" do
      tree = Merkle.build([
        {"lib/a.ex", %{version: 1}},
        {"lib/a.ex", %{version: 2}}
      ])

      # Map.new keeps last — only 1 leaf
      assert tree.leaf_count == 1
      assert Merkle.verify(tree) == :ok
    end
  end

  # ============================================================================
  # Tampered internal nodes
  # ============================================================================

  describe "tampered tree" do
    test "tampered leaf hash detected by verify" do
      tree = Merkle.build([{"a.ex", %{x: 1}}, {"b.ex", %{x: 2}}])
      tampered = %{tree | leaves: Map.put(tree.leaves, "a.ex", <<0::256>>)}
      assert Merkle.verify(tampered) == {:error, :corrupted}
    end

    test "tampered root hash detected by verify" do
      tree = Merkle.build([{"a.ex", %{x: 1}}, {"b.ex", %{x: 2}}])
      tampered_root = %{tree.root | hash: <<0::256>>}
      tampered = %{tree | root: tampered_root}
      assert Merkle.verify(tampered) == {:error, :corrupted}
    end

    test "swapped leaf hashes detected" do
      tree = Merkle.build([{"a.ex", %{x: 1}}, {"b.ex", %{x: 2}}])
      hash_a = tree.leaves["a.ex"]
      hash_b = tree.leaves["b.ex"]

      # Swap the hashes
      swapped_leaves = tree.leaves |> Map.put("a.ex", hash_b) |> Map.put("b.ex", hash_a)
      tampered = %{tree | leaves: swapped_leaves}
      assert Merkle.verify(tampered) == {:error, :corrupted}
    end
  end

  # ============================================================================
  # Remove nonexistent leaf
  # ============================================================================

  describe "remove_leaf edge cases" do
    test "removing nonexistent leaf is a no-op" do
      tree = Merkle.build([{"a.ex", %{x: 1}}])
      result = Merkle.remove_leaf(tree, "nonexistent.ex")

      assert result.leaf_count == 1
      assert Merkle.root_hash(result) == Merkle.root_hash(tree)
    end

    test "removing all leaves one by one" do
      tree = Merkle.build([{"a.ex", %{x: 1}}, {"b.ex", %{x: 2}}, {"c.ex", %{x: 3}}])

      tree = Merkle.remove_leaf(tree, "a.ex")
      assert tree.leaf_count == 2
      assert Merkle.verify(tree) == :ok

      tree = Merkle.remove_leaf(tree, "b.ex")
      assert tree.leaf_count == 1
      assert Merkle.verify(tree) == :ok

      tree = Merkle.remove_leaf(tree, "c.ex")
      assert tree.leaf_count == 0
      assert tree.root == nil
    end
  end

  # ============================================================================
  # Diff edge cases
  # ============================================================================

  describe "diff edge cases" do
    test "diff between empty and populated tree" do
      empty = Merkle.build([])
      populated = Merkle.build([{"a.ex", %{x: 1}}, {"b.ex", %{x: 2}}])

      diff = Merkle.diff(empty, populated)
      assert length(diff) == 2
      assert "a.ex" in diff
      assert "b.ex" in diff
    end

    test "diff between populated and empty tree" do
      populated = Merkle.build([{"a.ex", %{x: 1}}])
      empty = Merkle.build([])

      diff = Merkle.diff(populated, empty)
      assert diff == ["a.ex"]
    end

    test "diff is symmetric for added/removed files" do
      tree_a = Merkle.build([{"a.ex", %{x: 1}}])
      tree_b = Merkle.build([{"b.ex", %{x: 2}}])

      diff_ab = Merkle.diff(tree_a, tree_b) |> Enum.sort()
      diff_ba = Merkle.diff(tree_b, tree_a) |> Enum.sort()
      assert diff_ab == diff_ba
    end

    test "diff two empty trees" do
      assert Merkle.diff(Merkle.build([]), Merkle.build([])) == []
    end
  end

  # ============================================================================
  # ETF determinism
  # ============================================================================

  describe "hash determinism" do
    test "same map data produces same hash regardless of key order" do
      # Elixir maps don't have ordering, but :erlang.term_to_binary is deterministic
      # for the same structural content
      ast_a = %{modules: [%{name: "A", line: 1}], functions: [%{name: :foo, arity: 0}]}
      ast_b = %{functions: [%{name: :foo, arity: 0}], modules: [%{name: "A", line: 1}]}

      tree_a = Merkle.build([{"test.ex", ast_a}])
      tree_b = Merkle.build([{"test.ex", ast_b}])

      assert Merkle.root_hash(tree_a) == Merkle.root_hash(tree_b)
    end

    test "building tree twice gives same root" do
      pairs = for i <- 1..50, do: {"lib/m#{i}.ex", %{i: i}}

      root1 = Merkle.build(pairs) |> Merkle.root_hash()
      root2 = Merkle.build(pairs) |> Merkle.root_hash()

      assert root1 == root2
    end
  end

  # ============================================================================
  # Special file paths
  # ============================================================================

  describe "special file paths" do
    test "unicode file paths" do
      tree = Merkle.build([
        {"lib/ñ_módulo.ex", %{x: 1}},
        {"lib/日本語.ex", %{x: 2}}
      ])

      assert tree.leaf_count == 2
      assert Merkle.verify(tree) == :ok
    end

    test "deeply nested paths" do
      deep_path = Enum.join(["lib"] ++ Enum.map(1..20, &"level_#{&1}"), "/") <> "/deep.ex"
      tree = Merkle.build([{deep_path, %{x: 1}}])
      assert tree.leaf_count == 1
    end

    test "empty string path" do
      tree = Merkle.build([{"", %{x: 1}}])
      assert tree.leaf_count == 1
      assert Merkle.verify(tree) == :ok
    end
  end

  # ============================================================================
  # file_content_hash
  # ============================================================================

  describe "file_content_hash" do
    test "returns nil for nonexistent file" do
      assert Merkle.file_content_hash("/nonexistent/file.ex") == nil
    end

    test "returns SHA-256 for real file" do
      path = Path.join(System.tmp_dir!(), "merkle_hash_test_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "hello world")

      hash = Merkle.file_content_hash(path)
      assert is_binary(hash)
      assert byte_size(hash) == 32
      assert hash == :crypto.hash(:sha256, "hello world")

      File.rm!(path)
    end

    test "different content produces different hash" do
      path = Path.join(System.tmp_dir!(), "merkle_hash_diff_#{:rand.uniform(100_000)}.ex")

      File.write!(path, "version 1")
      hash1 = Merkle.file_content_hash(path)

      File.write!(path, "version 2")
      hash2 = Merkle.file_content_hash(path)

      assert hash1 != hash2

      File.rm!(path)
    end
  end
end
