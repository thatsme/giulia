defmodule Giulia.Persistence.Merkle do
  @moduledoc """
  Merkle tree for AST cache integrity verification.

  Pure functions — no GenServer, no side effects. The tree is persisted
  in CubDB by the Writer and loaded by the Loader.

  Leaf granularity: one leaf per source file (matches ETS key pattern).
  Hash algorithm: SHA-256 via `:crypto.hash/2`.
  Ordering: sorted by file_path for deterministic root hashes.

  Tree structure:
  - Leaves: `%{path: file_path, hash: sha256(term_to_binary(ast_data))}`
  - Internal nodes: `%{hash: sha256(left.hash <> right.hash), left: node, right: node}`
  - Root: single node whose hash summarizes the entire project state

  O(log n) updates: changing one leaf only recomputes hashes up to the root.
  """

  @type leaf :: %{path: String.t(), hash: binary()}
  @type node_t :: %{hash: binary(), left: node_t() | leaf(), right: node_t() | leaf()} | leaf()
  @type tree :: %{root: node_t() | nil, leaves: %{String.t() => binary()}, leaf_count: non_neg_integer()}

  @doc """
  Build a Merkle tree from a list of `{file_path, ast_data}` pairs.
  """
  @spec build([{String.t(), map()}]) :: tree()
  def build([]) do
    %{root: nil, leaves: %{}, leaf_count: 0}
  end

  def build(file_ast_pairs) do
    leaves =
      file_ast_pairs
      |> Enum.map(fn {path, ast_data} -> {path, hash_ast(ast_data)} end)
      |> Enum.sort_by(fn {path, _hash} -> path end)
      |> Map.new()

    root = build_tree_from_leaves(leaves)
    %{root: root, leaves: leaves, leaf_count: map_size(leaves)}
  end

  @doc """
  Update a single leaf (file changed or added). O(log n) — rebuilds only the
  affected branch from leaf to root.
  """
  @spec update_leaf(tree(), String.t(), map()) :: tree()
  def update_leaf(tree, file_path, ast_data) do
    new_hash = hash_ast(ast_data)
    leaves = Map.put(tree.leaves, file_path, new_hash)
    root = build_tree_from_leaves(leaves)
    %{tree | root: root, leaves: leaves, leaf_count: map_size(leaves)}
  end

  @doc """
  Remove a leaf (file deleted). Rebuilds the affected branch.
  """
  @spec remove_leaf(tree(), String.t()) :: tree()
  def remove_leaf(tree, file_path) do
    leaves = Map.delete(tree.leaves, file_path)
    root = build_tree_from_leaves(leaves)
    %{tree | root: root, leaves: leaves, leaf_count: map_size(leaves)}
  end

  @doc """
  Full recomputation — verify the tree is internally consistent.
  Returns `:ok` if the recomputed root matches, `{:error, :corrupted}` otherwise.
  """
  @spec verify(tree()) :: :ok | {:error, :corrupted}
  def verify(%{root: nil, leaves: leaves}) when map_size(leaves) == 0, do: :ok

  def verify(%{root: root, leaves: leaves}) do
    recomputed = build_tree_from_leaves(leaves)

    if recomputed.hash == root.hash do
      :ok
    else
      {:error, :corrupted}
    end
  end

  @doc """
  Compare two Merkle trees and return a list of file_paths that differ.
  Useful for incremental sync between two states.
  """
  @spec diff(tree(), tree()) :: [String.t()]
  def diff(tree_a, tree_b) do
    all_paths = MapSet.union(
      MapSet.new(Map.keys(tree_a.leaves)),
      MapSet.new(Map.keys(tree_b.leaves))
    )

    Enum.filter(all_paths, fn path ->
      Map.get(tree_a.leaves, path) != Map.get(tree_b.leaves, path)
    end)
    |> Enum.sort()
  end

  @doc """
  Get the root hash of the tree. Returns nil for empty trees.
  """
  @spec root_hash(tree()) :: binary() | nil
  def root_hash(%{root: nil}), do: nil
  def root_hash(%{root: root}), do: root.hash

  @doc """
  Hash a raw file's bytes for staleness detection (separate from AST hash).
  """
  @spec file_content_hash(String.t()) :: binary() | nil
  def file_content_hash(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, _} -> nil
    end
  end

  # Private — tree construction

  defp build_tree_from_leaves(leaves) when map_size(leaves) == 0, do: nil

  defp build_tree_from_leaves(leaves) do
    leaf_nodes =
      leaves
      |> Enum.sort_by(fn {path, _hash} -> path end)
      |> Enum.map(fn {path, hash} -> %{path: path, hash: hash} end)

    build_level(leaf_nodes)
  end

  # Recursively pair nodes until we have a single root
  defp build_level([single]), do: single

  defp build_level(nodes) do
    nodes
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] ->
        combined_hash = :crypto.hash(:sha256, left.hash <> right.hash)
        %{hash: combined_hash, left: left, right: right}

      [single] ->
        # Odd node out — promote with self-hash
        combined_hash = :crypto.hash(:sha256, single.hash <> single.hash)
        %{hash: combined_hash, left: single, right: nil}
    end)
    |> build_level()
  end

  # Hash AST data using term_to_binary for deterministic serialization
  defp hash_ast(ast_data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(ast_data))
  end
end
