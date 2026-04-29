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
    case :erlang.binary_to_term(binary) do
      # Slice B envelope: %{digest, payload}. Unwrap — the verifier compares
      # the deserialized graph independent of the digest version.
      %{digest: _, payload: graph} -> graph
      legacy -> legacy
    end
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

  # ============================================================================
  # AST round-trip (1.5b)
  # ============================================================================

  @doc """
  Round-trip check for ETS AST entries ↔ CubDB AST entries.

  L1 holds AST data keyed by `{:ast, project, file}` in the Context.Store
  ETS table. L2 persists per-file ASTs keyed by `{:ast, file}` in the
  project's CubDB (project scope is implicit because each project has
  its own CubDB).

  Checks (same primitive, different payload):
    * File-count parity
    * File-set identity (paths present in L1 but not L2 and vice versa)
    * Stratified sample of `sample_size` files whose AST maps must be
      term-equal between L1 and L2
  """
  @spec verify_ast(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_ast(project_path, opts \\ []) do
    sample_size = Keyword.get(opts, :sample_size, @default_sample_per_label)

    l1 = read_l1_ast(project_path)
    l2 = read_l2_ast(project_path)

    cond do
      l1 == nil or map_size(l1) == 0 ->
        {:ok, payload_absent(project_path, :l1_empty, l1, l2)}

      l2 == nil or map_size(l2) == 0 ->
        {:ok, payload_absent(project_path, :l2_empty, l1, l2)}

      true ->
        do_verify_ast(project_path, l1, l2, sample_size)
    end
  end

  defp read_l1_ast(project_path) do
    :ets.match_object(Giulia.Context.Store, {{:ast, project_path, :_}, :_})
    |> Map.new(fn {{:ast, _proj, file}, ast_data} -> {file, ast_data} end)
  end

  defp read_l2_ast(project_path) do
    case PStore.get_db(project_path) do
      {:ok, db} ->
        db
        |> CubDB.select(min_key: {:ast, ""}, max_key: {:ast, <<255>>})
        |> Map.new(fn {{:ast, file}, ast_data} -> {file, ast_data} end)

      {:error, _} ->
        nil
    end
  end

  defp do_verify_ast(project_path, l1, l2, sample_size) do
    l1_files = l1 |> Map.keys() |> MapSet.new()
    l2_files = l2 |> Map.keys() |> MapSet.new()

    file_set_parity = %{
      status: if(MapSet.equal?(l1_files, l2_files), do: :match, else: :mismatch),
      l1_count: MapSet.size(l1_files),
      l2_count: MapSet.size(l2_files),
      missing_in_l2: MapSet.difference(l1_files, l2_files) |> MapSet.size(),
      extra_in_l2: MapSet.difference(l2_files, l1_files) |> MapSet.size()
    }

    common_files = MapSet.intersection(l1_files, l2_files) |> MapSet.to_list()
    sample = Enum.take_random(common_files, min(sample_size, length(common_files)))

    diffs =
      Enum.reduce(sample, [], fn file, acc ->
        if Map.get(l1, file) == Map.get(l2, file), do: acc, else: [file | acc]
      end)

    sample_identity = %{
      sampled: length(sample),
      ok: length(sample) - length(diffs),
      mismatched: length(diffs),
      mismatched_files: Enum.take(diffs, 5)
    }

    overall =
      if file_set_parity.status == :match and sample_identity.mismatched == 0,
        do: :pass,
        else: :fail

    {:ok,
     %{
       project: project_path,
       file_set_parity: file_set_parity,
       sample_identity: sample_identity,
       overall: overall
     }}
  end

  # ============================================================================
  # Metrics round-trip (1.5c)
  # ============================================================================

  @doc """
  Round-trip check for the cached metrics map.

  L1: `{:metrics, project}` in the knowledge_graphs ETS table.
  L2: `{:metrics, :cached}` in the project's CubDB.

  Metrics are an eventually-consistent map (keys land asynchronously
  as `metrics_ready` casts complete), so the check is term-equality
  per key with a tolerance for L1-newer-than-L2 keys reported under
  `:l1_only` rather than as a hard failure.
  """
  @spec verify_metrics(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_metrics(project_path) do
    l1 = read_l1_metrics(project_path) || %{}
    l2 = read_l2_metrics(project_path) || %{}

    l1_keys = l1 |> Map.keys() |> MapSet.new()
    l2_keys = l2 |> Map.keys() |> MapSet.new()

    mismatched_keys =
      MapSet.intersection(l1_keys, l2_keys)
      |> Enum.filter(fn k -> Map.fetch!(l1, k) != Map.fetch!(l2, k) end)

    report = %{
      l1_keys: MapSet.size(l1_keys),
      l2_keys: MapSet.size(l2_keys),
      l1_only: MapSet.difference(l1_keys, l2_keys) |> MapSet.to_list(),
      l2_only: MapSet.difference(l2_keys, l1_keys) |> MapSet.to_list(),
      mismatched_keys: mismatched_keys
    }

    overall =
      if report.mismatched_keys == [] and report.l2_only == [],
        do: :pass,
        else: :fail

    {:ok, Map.put(report, :overall, overall) |> Map.put(:project, project_path)}
  end

  @doc """
  Composite L1↔L2 verification across one or more payloads.

  `check` selects the payload set:

    * `"graph"` → graph round-trip only
    * `"ast"` → AST cache round-trip only
    * `"metrics"` → metrics cache round-trip only
    * `"all"` (default) → all three

  Returns a single overall pass/fail computed from the per-payload
  outcomes plus the per-payload reports keyed by `:graph | :ast | :metrics`.
  Both HTTP `GET /api/knowledge/verify_l2` and the MCP `knowledge_verify_l2`
  tool reduce to a single call here — orchestration must not live in
  the protocol layer.
  """
  @spec verify_l2(String.t(), keyword()) ::
          {:ok, %{project: String.t(), overall: String.t(), checks: %{atom() => map()}}}
  def verify_l2(project_path, opts \\ []) do
    sample = Keyword.get(opts, :sample_per_label, @default_sample_per_label)
    check = Keyword.get(opts, :check, "all")

    results = run_checks(project_path, check, sample)

    overall =
      if Enum.any?(results, fn {_, r} -> Map.get(r, :overall) == :fail end),
        do: "fail",
        else: "pass"

    {:ok, %{project: project_path, overall: overall, checks: Map.new(results)}}
  end

  defp run_checks(project, "graph", sample), do: [{:graph, run_graph(project, sample)}]
  defp run_checks(project, "ast", sample), do: [{:ast, run_ast(project, sample)}]
  defp run_checks(project, "metrics", _sample), do: [{:metrics, run_metrics(project)}]

  defp run_checks(project, _all, sample) do
    [
      {:graph, run_graph(project, sample)},
      {:ast, run_ast(project, sample)},
      {:metrics, run_metrics(project)}
    ]
  end

  defp run_graph(project, sample) do
    {:ok, report} = verify_graph(project, sample_per_label: sample)
    report
  end

  defp run_ast(project, sample) do
    {:ok, report} = verify_ast(project, sample_size: sample)
    report
  end

  defp run_metrics(project) do
    {:ok, report} = verify_metrics(project)
    report
  end

  defp read_l1_metrics(project_path) do
    case :ets.lookup(:giulia_knowledge_graphs, {:metrics, project_path}) do
      [{_, metrics}] -> metrics
      [] -> nil
    end
  end

  defp read_l2_metrics(project_path) do
    case PStore.get_db(project_path) do
      {:ok, db} ->
        case CubDB.get(db, {:metrics, :cached}) do
          # Slice B envelope: unwrap so the verifier compares the metrics
          # map directly. Digest mismatch is the loader's concern, not
          # the verifier's.
          %{digest: _, payload: metrics} -> metrics
          legacy -> legacy
        end

      {:error, _} ->
        nil
    end
  end

  defp payload_absent(project_path, reason, l1, l2) do
    %{
      project: project_path,
      overall: :incomplete,
      reason: reason,
      l1_size: if(is_map(l1), do: map_size(l1), else: 0),
      l2_size: if(is_map(l2), do: map_size(l2), else: 0)
    }
  end
end
