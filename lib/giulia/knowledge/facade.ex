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

  Functions here return PLAIN DATA, never a `Plug.Conn` — so MCP dispatch can
  call them directly. Each protocol renders the result in its own idiom:

    * `resolve_ready/1` returns `{:ok, path}` | `{:error, :missing_path}` |
      `{:not_ready, info}`. REST renders 400/409; MCP renders the SAME `info`
      as a binary error string that MUST carry the actionable hint (a bare
      `{:error, :not_ready}` would reach the agent as `:not_ready` with no
      hint — see `Giulia.MCP.Server` error rendering).

  Built first on `impact` (Build proxy commit 2) as the reviewed template
  before replicating to style_oracle/search, unprotected_hubs, duplicates.
  """

  alias Giulia.Core.PathMapper
  alias Giulia.Daemon.Helpers
  alias Giulia.Knowledge.Store

  @type ready_info :: %{state: atom(), reason: String.t(), hint: String.t(), path: String.t()}
  @type resolve_result ::
          {:ok, String.t()} | {:error, :missing_path} | {:not_ready, ready_info()}

  @doc """
  Resolve `params["path"]` and check scan readiness in one shared step.

  Single source for both protocols. The readiness decision reuses the pure
  `Helpers.scan_state/1`; the actionable hint is attached here so it survives
  to whichever surface renders it.
  """
  @spec resolve_ready(map()) :: resolve_result()
  def resolve_ready(params) do
    case params["path"] do
      blank when blank in [nil, ""] ->
        {:error, :missing_path}

      raw ->
        path = PathMapper.resolve_path(raw)

        case Helpers.scan_state(path) do
          :ready ->
            {:ok, path}

          {:pending, reason} ->
            {:not_ready,
             %{
               state: :scan_in_progress,
               reason: reason,
               hint: "GET /api/index/status?path=... to poll until status=idle",
               path: path
             }}

          {:not_indexed, reason} ->
            {:not_ready,
             %{
               state: :not_indexed,
               reason: reason,
               hint: "POST /api/index/scan with this path first",
               path: path
             }}
        end
    end
  end

  @doc """
  Render a `{:not_ready, info}` result as a single binary string carrying the
  hint — for surfaces (MCP) whose error channel is a plain string. REST renders
  `info` structurally (409 + fields) instead.
  """
  @spec not_ready_message(ready_info()) :: String.t()
  def not_ready_message(%{reason: reason, hint: hint}), do: "#{reason} — #{hint}"

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
end
