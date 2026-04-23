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
  Verify L1→L3 CALLS identity for `project_path`.

  Options:
    * `:sample_per_bucket` — per-bucket sample size (default #{@default_sample_per_bucket})

  Returns `{:ok, %{report: %{bucket => bucket_result}, l3_calls_total: n,
  overall: :pass | :fail}}`.
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

      overall = if any_failure?(report), do: :fail, else: :pass

      {:ok,
       %{
         project: project_path,
         l3_calls_total: l3_total,
         l1_calls_total: length(edges),
         report: report,
         overall: overall
       }}
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
    sql = """
    SELECT count(*) AS n FROM CALLS
    WHERE project = :project AND out.name = :from AND in.name = :to
    """

    case Client.query(sql, "sql", %{project: project_path, from: from_mfa, to: to_mfa}) do
      {:ok, [%{"n" => 0}]} -> :missing
      {:ok, [%{"n" => n}]} when is_integer(n) and n > 0 -> :ok
      {:ok, other} -> {:error, {:unexpected_shape, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_l3_calls(project_path) do
    sql = "SELECT count(*) AS n FROM CALLS WHERE project = :project"

    case Client.query(sql, "sql", %{project: project_path}) do
      {:ok, [%{"n" => n}]} when is_integer(n) -> {:ok, n}
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
