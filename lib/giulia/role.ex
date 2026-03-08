defmodule Giulia.Role do
  @moduledoc """
  Role detection for monitor/worker architecture.

  Reads `GIULIA_ROLE` env var to determine container role:
  - `:standalone` (default) — full supervision tree, single-container mode
  - `:worker` — full tree, does heavy work (scans, graphs, embeddings)
  - `:monitor` — lightweight tree, watches a worker via distributed Erlang
  """

  @spec role() :: :standalone | :worker | :monitor
  def role do
    case System.get_env("GIULIA_ROLE", "standalone") do
      "monitor" -> :monitor
      "worker" -> :worker
      _ -> :standalone
    end
  end

  @spec monitor?() :: boolean()
  def monitor?, do: role() == :monitor

  @spec worker?() :: boolean()
  def worker?, do: role() == :worker

  @spec standalone?() :: boolean()
  def standalone?, do: role() == :standalone
end
