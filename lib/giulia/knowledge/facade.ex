defmodule Giulia.Knowledge.Facade do
  @moduledoc """
  The protocol edge for knowledge endpoints, shared by the REST router and MCP
  dispatch. It holds — ONCE — what was previously re-implemented per protocol:

    * path resolution (`PathMapper` host→container)
    * readiness (scan-state gate)
    * string→typed coercion + defaults
    * response normalization

  …then calls the pure, typed `Giulia.Knowledge.Store`. Store stays untouched:
  typed positional args, semantic validation, `{:not_found}` backstop. It does
  not learn about string params, HTTP defaults, or readiness.

  Per-domain coercion + Store calls live here; the domain-agnostic edge
  (resolution + readiness) lives in `Giulia.Daemon.Edge`, shared with other
  domains' facades. Functions here return PLAIN DATA, never a `Plug.Conn`.

  Built first on `impact` (proxy commit 2) as the reviewed template before
  replicating to style_oracle, unprotected_hubs, duplicates (and Search.Facade
  for search/semantic).
  """

  alias Giulia.Daemon.Helpers
  alias Giulia.Intelligence.{EmbeddingServing, SemanticIndex}
  alias Giulia.Knowledge.Store

  # ===========================================================================
  # impact — first bucket-3 endpoint through the facade
  # ===========================================================================

  @doc """
  Impact map for a module. Owns the `depth` default (was triplicated across
  `@skill`, the REST route, and MCP dispatch) and the upstream/downstream/
  function-edge normalization (was copy-pasted in REST + MCP). `path` is
  pre-resolved by `resolve_ready/1`; `module` is forwarded raw — `Store`
  backstops a nil/unknown module with `{:not_found}`.
  """
  @spec impact(String.t(), map()) ::
          {:ok, map()} | {:error, {:not_found, map()}}
  def impact(path, params) do
    depth = Helpers.parse_int_param(params["depth"], 2)

    case Store.impact_map(path, params["module"], depth) do
      {:ok, result} ->
        {:ok, normalize_impact(result)}

      {:error, {:not_found, _vertex, suggestions, graph_info}} ->
        {:error,
         {:not_found,
          %{module: params["module"], suggestions: suggestions, graph_info: graph_info}}}
    end
  end

  # ===========================================================================
  # pre_impact_check — RESPONSE-path schema_version stamp (single source)
  # ===========================================================================

  @doc """
  Rename/remove risk analysis. This is a RESPONSE-shape addition only: the raw
  param map is forwarded to `Store.pre_impact_check/2` unchanged — Store owns the
  action enum and the module/target validation (no re-coerce, no re-gate here) —
  and `:schema_version` is stamped onto the `{:ok}` result so BOTH protocols
  inherit it from one place (was REST-only, hand-written). The stamp lets
  refactor-safety loops compare against a known-complete extractor/graph-builder
  version (v8, the graph-completeness fix; see CHANGELOG v0.2.2). Error tuples
  pass through untouched for each protocol to render.
  """
  @spec pre_impact_check(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def pre_impact_check(path, params) do
    case Store.pre_impact_check(path, params) do
      {:ok, result} ->
        {:ok, Map.put(result, :schema_version, Giulia.Persistence.Store.schema_version())}

      other ->
        other
    end
  end

  defp normalize_impact(result) do
    %{
      result
      | upstream: Enum.map(result.upstream, fn {v, d} -> %{module: v, depth: d} end),
        downstream: Enum.map(result.downstream, fn {v, d} -> %{module: v, depth: d} end),
        function_edges:
          Enum.map(result.function_edges, fn {name, targets} ->
            %{function: name, calls: targets}
          end)
    }
  end

  # ===========================================================================
  # style_oracle — exemplar functions by concept (semantic)
  # ===========================================================================

  @doc """
  Style-oracle exemplars. Owns the `top_k` default (was triplicated). `q` is
  forwarded raw — it is required and NOT nil-safe in `Store.style_oracle`
  (embeds the query), so the protocol edge gates it (REST 400 / MCP
  require_param). Returns `Store`'s result verbatim, including the
  `"Semantic search unavailable"` error each protocol renders (REST 503 / MCP
  error string) — an explicit signal, not a silent empty.
  """
  @spec style_oracle(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def style_oracle(path, params) do
    top_k = Helpers.parse_int_param(params["top_k"], 3)
    Store.style_oracle(path, params["q"], top_k)
  end

  # ===========================================================================
  # unprotected_hubs — hubs with weak spec/doc coverage
  # ===========================================================================

  @doc """
  Unprotected hubs. Owns the `hub_threshold` (3) and `spec_threshold` (0.5)
  defaults (were triplicated). No required param beyond `path` — both thresholds
  default, so no nil reaches `Store` and there is no edge gate to keep.
  """
  @spec unprotected_hubs(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def unprotected_hubs(path, params) do
    Store.find_unprotected_hubs(path,
      hub_threshold: Helpers.parse_int_param(params["hub_threshold"], 3),
      spec_threshold: Helpers.parse_float_param(params["spec_threshold"], 0.5)
    )
  end

  # ===========================================================================
  # duplicates — semantic dedup (SECOND readiness dimension: embeddings)
  # ===========================================================================

  @doc """
  Actionable message for the embedding-availability dimension. Distinct from
  scan-readiness (`Daemon.Edge`): embeddings can be absent even on a scanned
  project — e.g. the monitor role doesn't load `EmbeddingServing`. Tells the
  agent WHERE to go rather than leaving an unexplained empty/error.
  """
  @spec embedding_unavailable_message() :: String.t()
  def embedding_unavailable_message do
    "EmbeddingServing not loaded for this role — query the worker on :4000"
  end

  @doc """
  Semantic duplicate clusters. Owns the `threshold` (0.85) / `max` (20) defaults
  and a SECOND, orthogonal readiness check: embedding availability. Scan
  readiness is the edge's job (`Daemon.Edge`); embeddings are this endpoint's
  dependency, so the check lives here — a clean `EmbeddingServing.available?()`
  predicate (registry presence, not exception-translation; verified). On
  unavailable, or when the project has no embeddings, returns
  `{:error, :embedding_unavailable}` so each protocol renders the actionable
  "query the worker" signal instead of an unexplained empty/"not loaded".
  """
  @spec duplicates(String.t(), map()) ::
          {:ok, term()} | {:error, :embedding_unavailable} | {:error, term()}
  def duplicates(path, params) do
    if EmbeddingServing.available?() do
      opts = [
        threshold: Helpers.parse_float_param(params["threshold"], 0.85),
        max: Helpers.parse_int_param(params["max"], 20),
        relevance: params["relevance"]
      ]

      case SemanticIndex.find_duplicates(path, opts) do
        {:ok, result} -> {:ok, result}
        {:error, "Semantic search unavailable" <> _} -> {:error, :embedding_unavailable}
        {:error, "No embeddings" <> _} -> {:error, :embedding_unavailable}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :embedding_unavailable}
    end
  end
end
