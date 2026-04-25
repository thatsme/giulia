defmodule Giulia.Knowledge.CodeDigest do
  @moduledoc """
  Identity hash of the modules whose code shape determines L2-cached
  output (graph + metrics). When any of them changes, persisted caches
  tagged with a previous digest are silently dropped on warm-restore so
  the daemon recomputes from existing ASTs — eliminates "edited the
  builder, daemon still serves stale dead_code" without forcing
  re-extraction.

  Scope is deliberately narrow: AST extraction stays outside this digest.
  Re-extracting 580+ files takes seconds-to-tens-of-seconds; auto-running
  it on every metric/builder edit would be wrong. AST-cache invalidation
  is the user's job via `POST /api/index/scan` with `force: true`. This
  module covers the cheap downstream path — graph rebuild + metric
  recompute from existing ASTs.

  The hash is computed once per VM and cached in `:persistent_term`. Reads
  are free; writes only happen on the first call after boot.
  """

  @tier_modules [
    Giulia.Knowledge.Builder,
    Giulia.Knowledge.Metrics,
    Giulia.Knowledge.Behaviours,
    Giulia.Knowledge.DispatchPatterns
  ]

  @persistent_term_key {__MODULE__, :digest}

  @doc """
  Returns the current 12-char hex digest of the loaded tier modules.
  """
  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        digest = compute()
        :persistent_term.put(@persistent_term_key, digest)
        digest

      digest ->
        digest
    end
  end

  @doc """
  Force-recompute the digest (after a hot-code-load test scenario, for
  example). Production code should use `current/0`.
  """
  @spec recompute() :: String.t()
  def recompute do
    digest = compute()
    :persistent_term.put(@persistent_term_key, digest)
    digest
  end

  defp compute do
    @tier_modules
    |> Enum.map_join("|", fn mod ->
      try do
        mod.module_info(:md5) |> Base.encode16(case: :lower)
      rescue
        _ -> "missing:#{inspect(mod)}"
      end
    end)
    |> then(&:erlang.md5/1)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
