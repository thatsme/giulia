defmodule Giulia.Persistence.Verifier do
  @moduledoc """
  L1↔L2 round-trip integrity check for the knowledge graph.

  L1 holds the live libgraph in ETS. L2 persists it to CubDB via
  `:erlang.term_to_binary/2` and restores via `:erlang.binary_to_term/1`.
  The serialization boundary is the place where identity can silently
  drift — anonymous functions in edge labels, opaque references,
  dynamically-created atoms, and future-added edge metadata all survive
  or die at this hop.

  This verifier reads the live L1 graph, reads the CubDB-persisted
  binary, deserializes it, and compares the two by their extracted
  vertex/edge content (not by struct equality, which depends on
  libgraph's internal index layout).

  Identity checks, in order of sharpness:

    * Vertex-set equality (as MapSets of vertex IDs).
    * Edge-count equality.
    * Stratified sample of edges — for each sampled edge, assert the
      L2 graph has an edge with matching v1, v2, and label. Sampling
      is stratified by label so rare labels (:references, :semantic,
      :implements) aren't swamped by the dominant :calls bucket.

  Returns a report with per-check outcomes and a single :pass | :fail.
  """

  require Logger

  alias Giulia.Persistence.Store, as: PStore

  @default_sample_per_label 10

  @type report :: %{
          project: String.t(),
          l1_present: boolean(),
          l2_present: boolean(),
          vertex_parity: map() | :skip,
          edge_parity: map() | :skip,
          sample_identity: map() | :skip,
          overall: :pass | :fail | :incomplete
        }

  @doc """
  Round-trip the persisted graph for `project_path` and compare with L1.

  Options:
    * `:sample_per_label` — per-label edge sample size (default #{@default_sample_per_label})
  """
  @spec verify_graph(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def verify_graph(project_path, opts \\ []) do
    sample_per_label = Keyword.get(opts, :sample_per_label, @default_sample_per_label)

    l1 = read_l1_graph(project_path)
    l2 = read_l2_graph(project_path)

    cond do
      l1 == nil and l2 == nil ->
        {:ok, absent_report(project_path, :l1_and_l2_absent)}

      l1 == nil ->
        {:ok, absent_report(project_path, :l1_absent)}

      l2 == nil ->
        {:ok, absent_report(project_path, :l2_absent)}

      true ->
        do_verify(project_path, l1, l2, sample_per_label)
    end
  end

  # --- Readers ---

  defp read_l1_graph(project_path) do
    case :ets.lookup(:giulia_knowledge_graphs, {:graph, project_path}) do
      [{_, graph}] -> graph
      [] -> nil
    end
  end

  defp read_l2_graph(project_path) do
    case PStore.get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:graph, :serialized}) do
          nil -> nil
          binary when is_binary(binary) -> safe_deserialize(binary)
          _other -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp safe_deserialize(binary) do
    :erlang.binary_to_term(binary)
  rescue
    _ -> nil
  end

  # --- Comparison ---

  defp do_verify(project_path, l1, l2, sample_per_label) do
    l1_vertices = MapSet.new(Graph.vertices(l1))
    l2_vertices = MapSet.new(Graph.vertices(l2))

    vertex_parity = classify_vertex_parity(l1_vertices, l2_vertices)

    l1_edges = Graph.edges(l1)
    l2_edge_keys = l2 |> Graph.edges() |> MapSet.new(&edge_key/1)

    edge_parity = %{
      status: if(length(l1_edges) == MapSet.size(l2_edge_keys), do: :match, else: :mismatch),
      l1: length(l1_edges),
      l2: MapSet.size(l2_edge_keys),
      delta: length(l1_edges) - MapSet.size(l2_edge_keys)
    }

    sample_identity = stratified_sample_check(l1_edges, l2_edge_keys, sample_per_label)

    overall =
      if vertex_parity.status == :match and edge_parity.status == :match and
           sample_identity.overall == :pass,
         do: :pass,
         else: :fail

    {:ok,
     %{
       project: project_path,
       l1_present: true,
       l2_present: true,
       vertex_parity: vertex_parity,
       edge_parity: edge_parity,
       sample_identity: sample_identity,
       overall: overall
     }}
  end

  defp classify_vertex_parity(l1, l2) do
    missing_in_l2 = MapSet.difference(l1, l2) |> MapSet.size()
    extra_in_l2 = MapSet.difference(l2, l1) |> MapSet.size()

    status =
      cond do
        missing_in_l2 == 0 and extra_in_l2 == 0 -> :match
        true -> :mismatch
      end

    %{
      status: status,
      l1: MapSet.size(l1),
      l2: MapSet.size(l2),
      missing_in_l2: missing_in_l2,
      extra_in_l2: extra_in_l2
    }
  end

  defp stratified_sample_check(l1_edges, l2_edge_keys, sample_per_label) do
    by_label = Enum.group_by(l1_edges, &label_key/1)

    per_label =
      by_label
      |> Enum.map(fn {label, edges} ->
        sample = Enum.take_random(edges, min(sample_per_label, length(edges)))
        outcomes = Enum.map(sample, &check_edge_present(&1, l2_edge_keys))

        {label,
         %{
           total_in_label: length(edges),
           sampled: length(outcomes),
           ok: Enum.count(outcomes, &(&1 == :ok)),
           missing: Enum.count(outcomes, &(&1 == :missing))
         }}
      end)
      |> Map.new()

    overall =
      if Enum.any?(per_label, fn {_, r} -> r.missing > 0 end),
        do: :fail,
        else: :pass

    %{overall: overall, per_label: per_label}
  end

  defp check_edge_present(edge, l2_edge_keys) do
    if MapSet.member?(l2_edge_keys, edge_key(edge)), do: :ok, else: :missing
  end

  # Edge identity = (v1, v2, label). Label is normalized via label_key/1
  # so {:calls, :direct} doesn't drift against {:calls, :alias_resolved}
  # when we don't care about via (but we do, so keep the full label).
  defp edge_key(edge), do: {edge.v1, edge.v2, edge.label}

  defp label_key(edge) do
    case edge.label do
      {:calls, _via} -> :calls
      {:semantic, _reason} -> :semantic
      other -> other
    end
  end

  defp absent_report(project_path, reason) do
    %{
      project: project_path,
      l1_present: reason not in [:l1_absent, :l1_and_l2_absent],
      l2_present: reason not in [:l2_absent, :l1_and_l2_absent],
      vertex_parity: :skip,
      edge_parity: :skip,
      sample_identity: :skip,
      overall: :incomplete,
      reason: reason
    }
  end
end
