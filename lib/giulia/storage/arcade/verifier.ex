defmodule Giulia.Storage.Arcade.Verifier do
  @moduledoc """
  Sample-identity check: verifies function-level :calls edges round-trip
  from L1 (libgraph) to L3 (ArcadeDB CALLS edges) with matching endpoint
  MFA identities.

  Stratifies the sample across the `via` buckets emitted in Pass 4
  (:direct, :alias_resolved, :erlang_atom, :local) plus an orthogonal
  predicate/bang cross-cut (`?`/`!` function names). Uniform random
  sampling would over-represent the dominant :local bucket and miss the
  high-risk resolution buckets.

  This is deliberately the *correctness* test, not a performance test —
  O(sample_per_bucket * buckets) ArcadeDB queries per run.
  """

  require Logger

  alias Giulia.Knowledge.Store
  alias Giulia.Storage.Arcade.Client

  @default_sample_per_bucket 10

  @type edge :: {String.t(), String.t(), :calls, atom()}
  @type bucket_result :: %{
          total_in_bucket: non_neg_integer(),
          sampled: non_neg_integer(),
          ok: non_neg_integer(),
          missing: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Verify L1→L3 CALLS integrity for `project_path`.

  Runs two orthogonal checks:

    * **Sample identity** — stratified sample of function-level :calls
      edges from L1; each is looked up in L3 by MFA endpoints. Catches
      endpoint-mismatch bugs where edges exist but point at the wrong
      vertices.
    * **Count parity** — total L1 function :calls vs total L3 CALLS
      for the project. Catches accumulation bugs (duplicate edges from
      non-idempotent inserts) and loss bugs (partial writes) that
      sample identity alone misses by definition.

  Both checks must pass for `overall: :pass`. Neither alone is
  sufficient — together they cover the main failure modes of
  cross-store graph sync.

  Options:
    * `:sample_per_bucket` — per-bucket sample size (default #{@default_sample_per_bucket})

  Returns `{:ok, map}` with `:report`, `:count_parity`, `:l3_calls_total`,
  `:l1_calls_total`, `:overall`.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(project_path, opts \\ []) do
    sample_per_bucket = Keyword.get(opts, :sample_per_bucket, @default_sample_per_bucket)

    with {:ok, edges} <- Store.all_function_call_edges_with_via(project_path),
         {:ok, l3_total} <- count_l3_calls(project_path) do
      strata = stratify(edges)

      report =
        strata
        |> Enum.map(fn {bucket, items} ->
          sample = Enum.take_random(items, min(sample_per_bucket, length(items)))
          outcomes = Enum.map(sample, &verify_edge(project_path, &1))
          {bucket, summarize(outcomes, length(items))}
        end)
        |> Map.new()

      l1_total = length(edges)
      count_parity = classify_count_parity(l1_total, l3_total)

      overall =
        if any_failure?(report) or count_parity.status != :match,
          do: :fail,
          else: :pass

      {:ok,
       %{
         project: project_path,
         l3_calls_total: l3_total,
         l1_calls_total: l1_total,
         count_parity: count_parity,
         report: report,
         overall: overall
       }}
    end
  end

  defp classify_count_parity(l1, l3) do
    cond do
      l1 == l3 ->
        %{status: :match, l1: l1, l3: l3, delta: 0}

      l3 > l1 ->
        %{
          status: :l3_exceeds_l1,
          l1: l1,
          l3: l3,
          delta: l3 - l1,
          hint: "non-idempotent inserts or duplicate snapshots"
        }

      l3 < l1 ->
        %{
          status: :l3_under_l1,
          l1: l1,
          l3: l3,
          delta: l1 - l3,
          hint: "partial write, failed inserts, or stale L3"
        }
    end
  end

  # --- Stratification ---

  defp stratify(edges) do
    by_via = Enum.group_by(edges, fn {_, _, _, via} -> via end)

    predicate_bang =
      Enum.filter(edges, fn {_, to, _, _} ->
        String.contains?(to, "?") or String.contains?(to, "!")
      end)

    Map.put(by_via, :predicate_bang, predicate_bang)
  end

  # --- Per-edge verification ---

  @spec verify_edge(String.t(), edge()) :: :ok | :missing | {:error, term()}
  defp verify_edge(project_path, {from_mfa, to_mfa, :calls, _via}) do
    # ArcadeDB requires outV()/inV() function calls to traverse from edge to
    # vertex. The intuitive `out.name` / `in.name` property syntax silently
    # returns null and yields zero matches — a trap the verifier itself fell
    # into on first implementation.
    sql = """
    SELECT count(*) AS n FROM CALLS
    WHERE project = :project AND outV().name = :from AND inV().name = :to
    """

    case Client.query(sql, "sql", %{project: project_path, from: from_mfa, to: to_mfa}) do
      {:ok, [%{"n" => 0}]} -> :missing
      {:ok, [%{"n" => n}]} when is_integer(n) and n > 0 -> :ok
      {:ok, other} -> {:error, {:unexpected_shape, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Count L3 CALLS edges scoped to the project's most-recent build_id.
  # L1 always represents the CURRENT build (it lives in ETS and gets
  # rebuilt on each scan), so the round-trip parity check must compare
  # against the L3 build that was most recently snapshotted, not the
  # cumulative cross-build total. Pre-fix this would conflate
  # "non-idempotent duplicate inserts" (real bug) with "history
  # accumulation across N rescans" (working as designed). After the
  # 2026-04-29 fix, count_parity.status returns :match on a healthy
  # system regardless of how many prior builds are retained.
  #
  # Implemented as two queries (max build_id, then count) rather than
  # a nested SELECT — ArcadeDB's SQL parser handled the subquery
  # variant unstably on large CALLS tables (timeouts under load).
  defp count_l3_calls(project_path) do
    case latest_build_id(project_path) do
      {:ok, nil} ->
        {:ok, 0}

      {:ok, build_id} ->
        sql = """
        SELECT count(*) AS n FROM CALLS
        WHERE project = :project AND build_id = :build_id
        """

        case Client.query(sql, "sql", %{project: project_path, build_id: build_id}) do
          {:ok, [%{"n" => n}]} when is_integer(n) -> {:ok, n}
          {:ok, []} -> {:ok, 0}
          {:ok, other} -> {:error, {:unexpected_shape, other}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_build_id(project_path) do
    sql = "SELECT max(build_id) AS m FROM CALLS WHERE project = :project"

    case Client.query(sql, "sql", %{project: project_path}) do
      {:ok, [%{"m" => m}]} when is_integer(m) -> {:ok, m}
      {:ok, [%{"m" => nil}]} -> {:ok, nil}
      {:ok, []} -> {:ok, nil}
      {:ok, other} -> {:error, {:unexpected_shape, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Summarization ---

  defp summarize(outcomes, total) do
    freq = Enum.frequencies_by(outcomes, &classify/1)

    %{
      total_in_bucket: total,
      sampled: length(outcomes),
      ok: Map.get(freq, :ok, 0),
      missing: Map.get(freq, :missing, 0),
      errors: Map.get(freq, :error, 0)
    }
  end

  defp classify(:ok), do: :ok
  defp classify(:missing), do: :missing
  defp classify({:error, _}), do: :error

  defp any_failure?(report) do
    Enum.any?(report, fn {_bucket, r} -> r.missing > 0 or r.errors > 0 end)
  end
end
