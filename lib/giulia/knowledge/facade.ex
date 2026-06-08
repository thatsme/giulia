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
