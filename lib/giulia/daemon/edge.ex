defmodule Giulia.Daemon.Edge do
  @moduledoc """
  The protocol edge, shared by every domain and both protocols (REST routes and
  MCP dispatch). Holds the domain-agnostic edge concerns — path resolution and
  scan-readiness — so per-domain facades (`Knowledge.Facade`, `Search.Facade`,
  …) don't re-implement or cross-depend for them.

  Three layers: **edge** (this module — resolve + readiness) / **domain facade**
  (coerce + call Store) / **Store** (typed, pure semantics).

  Returns PLAIN DATA, never a `Plug.Conn`, so MCP dispatch can call it directly.
  Each protocol renders the result in its own idiom — REST as 400/409 + fields,
  MCP as a binary `{:error, message}` that MUST carry the actionable hint (a bare
  `{:error, :not_ready}` would reach the agent as `:not_ready` with no hint; see
  `Giulia.MCP.Server` error rendering).
  """

  alias Giulia.Core.PathMapper
  alias Giulia.Daemon.Helpers

  @type ready_info :: %{state: atom(), reason: String.t(), hint: String.t(), path: String.t()}
  @type resolve_result ::
          {:ok, String.t()} | {:error, :missing_path} | {:not_ready, ready_info()}

  @doc """
  Resolve `params["path"]` (host→container) and check scan readiness in one
  shared step. The readiness decision reuses the pure `Helpers.scan_state/1`;
  the actionable hint is attached here so it survives to whichever surface
  renders the result.
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
  Render a `{:not_ready, info}` payload as a single binary string carrying the
  hint — for surfaces (MCP) whose error channel is a plain string. REST renders
  `info` structurally (409 + fields) instead.
  """
  @spec not_ready_message(ready_info()) :: String.t()
  def not_ready_message(%{reason: reason, hint: hint}), do: "#{reason} — #{hint}"
end
