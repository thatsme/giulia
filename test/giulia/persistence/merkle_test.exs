defmodule Giulia.Persistence.MerkleTest do
  use ExUnit.Case, async: true

  alias Giulia.Persistence.Merkle

  @sample_ast %{modules: [%{name: "Foo", line: 1}], functions: []}

  describe "build/1" do
    test "empty list produces empty tree" do
      tree = Merkle.build([])
      assert tree.root == nil
      assert tree.leaves == %{}
      assert tree.leaf_count == 0
    end

    test "single file produces a tree with one leaf" do
      tree = Merkle.build([{"lib/foo.ex", @sample_ast}])
      assert tree.leaf_count == 1
      assert tree.root != nil
      assert tree.root.hash != nil
    end

    test "deterministic — same input always produces same root" do
      pairs = [{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}]
      tree_a = Merkle.build(pairs)
      tree_b = Merkle.build(pairs)
      assert Merkle.root_hash(tree_a) == Merkle.root_hash(tree_b)
    end

    test "order-independent — files are sorted by path" do
      pairs_a = [{"lib/b.ex", %{x: 2}}, {"lib/a.ex", %{x: 1}}]
      pairs_b = [{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}]
      assert Merkle.root_hash(Merkle.build(pairs_a)) == Merkle.root_hash(Merkle.build(pairs_b))
    end

    test "different data produces different root" do
      tree_a = Merkle.build([{"lib/a.ex", %{x: 1}}])
      tree_b = Merkle.build([{"lib/a.ex", %{x: 2}}])
      assert Merkle.root_hash(tree_a) != Merkle.root_hash(tree_b)
    end
  end

  describe "update_leaf/3" do
    test "updating a leaf changes the root hash" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}])
      updated = Merkle.update_leaf(tree, "lib/a.ex", %{x: 99})
      assert Merkle.root_hash(tree) != Merkle.root_hash(updated)
      assert updated.leaf_count == 2
    end

    test "adding a new leaf increases count" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}])
      updated = Merkle.update_leaf(tree, "lib/b.ex", %{x: 2})
      assert updated.leaf_count == 2
    end
  end

  describe "remove_leaf/2" do
    test "removing a leaf decreases count" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}])
      reduced = Merkle.remove_leaf(tree, "lib/a.ex")
      assert reduced.leaf_count == 1
    end

    test "removing last leaf produces empty tree" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}])
      empty = Merkle.remove_leaf(tree, "lib/a.ex")
      assert empty.root == nil
      assert empty.leaf_count == 0
    end
  end

  describe "verify/1" do
    test "freshly built tree verifies OK" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}])
      assert Merkle.verify(tree) == :ok
    end

    test "empty tree verifies OK" do
      tree = Merkle.build([])
      assert Merkle.verify(tree) == :ok
    end

    test "tampered tree detects corruption" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}])
      # Tamper with a leaf hash
      tampered_leaves = Map.put(tree.leaves, "lib/a.ex", <<0::256>>)
      tampered = %{tree | leaves: tampered_leaves}
      assert Merkle.verify(tampered) == {:error, :corrupted}
    end
  end

  describe "diff/2" do
    test "identical trees have no diff" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}])
      assert Merkle.diff(tree, tree) == []
    end

    test "detects changed files" do
      tree_a = Merkle.build([{"lib/a.ex", %{x: 1}}, {"lib/b.ex", %{x: 2}}])
      tree_b = Merkle.build([{"lib/a.ex", %{x: 99}}, {"lib/b.ex", %{x: 2}}])
      assert Merkle.diff(tree_a, tree_b) == ["lib/a.ex"]
    end

    test "detects added and removed files" do
      tree_a = Merkle.build([{"lib/a.ex", %{x: 1}}])
      tree_b = Merkle.build([{"lib/b.ex", %{x: 2}}])
      diff = Merkle.diff(tree_a, tree_b)
      assert "lib/a.ex" in diff
      assert "lib/b.ex" in diff
    end
  end

  describe "root_hash/1" do
    test "nil for empty tree" do
      assert Merkle.root_hash(Merkle.build([])) == nil
    end

    test "binary for non-empty tree" do
      tree = Merkle.build([{"lib/a.ex", %{x: 1}}])
      hash = Merkle.root_hash(tree)
      assert is_binary(hash)
      assert byte_size(hash) == 32
    end
  end
end
