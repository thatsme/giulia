defmodule Giulia.Knowledge.CodeDigest do
  @moduledoc """
  Identity hash of the modules **and config files** whose state determines
  L2-cached output (graph + metrics). When any of them changes, persisted
  caches tagged with a previous digest are silently dropped on warm-restore
  so the daemon recomputes from existing ASTs — eliminates "edited the
  builder/scoring.json, daemon still serves stale results" without forcing
  re-extraction.

  Scope is deliberately narrow: AST extraction stays outside this digest.
  Re-extracting 580+ files takes seconds-to-tens-of-seconds; auto-running
  it on every metric/builder/config edit would be wrong. AST-cache
  invalidation is the user's job via `POST /api/index/scan` with
  `force: true`. This module covers the cheap downstream path — graph
  rebuild + metric recompute from existing ASTs.

  Tracked surfaces:

  - **Code modules** (loaded BEAM md5): the graph/metric tier plus the
    enrichment tier — see `@tier_modules`. Editing any of these and
    recompiling shifts the digest.
  - **Config files** (file content md5): every `priv/config/*.json` whose
    values are baked into cached output — see `@tier_config_files`.
    Editing any of these and restarting the daemon shifts the digest.

  `priv/config/relevance.json` is deliberately **not** tracked. Its buckets
  are applied at read time when filtering a response, never baked into the
  cached graph or metrics, so an edit takes effect on the next request
  without invalidating anything. Every other config file feeds cached
  output and must be listed in `@tier_config_files` — otherwise an edit
  leaves stale caches validating against an unchanged digest.

  The hash is computed once per VM and cached in `:persistent_term`. Reads
  are free; writes only happen on the first call after boot.
  """

  @tier_modules [
    Giulia.Knowledge.Builder,
    Giulia.Knowledge.Metrics,
    Giulia.Knowledge.Behaviours,
    Giulia.Knowledge.DispatchPatterns,
    Giulia.Knowledge.DeadCodeClassifier,
    Giulia.Tools.TemplateReferences,
    Giulia.Enrichment.Registry,
    Giulia.Enrichment.Sources.Credo,
    Giulia.Enrichment.Sources.Dialyzer,
    Giulia.Enrichment.Ingest,
    Giulia.Enrichment.Consumer
  ]

  # Paths relative to :code.priv_dir(:giulia).
  #
  # EVERY config file whose contents are baked into tier output belongs here.
  # Omitting one means editing that JSON does not invalidate the cached
  # metrics, so the daemon serves stale results from before the edit —
  # silently, since nothing errors. Adding a new config file without adding it
  # here is the known failure mode, so make it a checklist item; the test
  # "every config file that feeds cached output is tracked by the digest"
  # enforces it against priv/config/*.json.
  #
  # `config/relevance.json` is the one deliberate exclusion: it is a
  # post-cache read-time response filter, never baked into cached output.
  # See the moduledoc.
  @tier_config_files [
    "config/scoring.json",
    "config/dispatch_patterns.json",
    "config/dispatch_invariants.json",
    "config/scan_defaults.json",
    "config/enrichment_sources.json",
    "config/otp_checks.json"
  ]

  @persistent_term_key {__MODULE__, :digest}

  @doc """
  Returns the current 12-char hex digest of the loaded tier modules + the
  contents of tier config files.
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
  Force-recompute the digest (after a hot-code-load test scenario or a
  config-file edit, for example). Production code should use `current/0`.
  """
  @spec recompute() :: String.t()
  def recompute do
    digest = compute()
    :persistent_term.put(@persistent_term_key, digest)
    digest
  end

  defp compute do
    module_part =
      @tier_modules
      |> Enum.map_join("|", fn mod ->
        try do
          mod.module_info(:md5) |> Base.encode16(case: :lower)
        rescue
          _ -> "missing:#{inspect(mod)}"
        end
      end)

    config_part =
      @tier_config_files
      |> Enum.map_join("|", fn relative_path ->
        path = Path.join(:code.priv_dir(:giulia), relative_path)

        case File.read(path) do
          {:ok, body} -> :erlang.md5(body) |> Base.encode16(case: :lower)
          {:error, _} -> "missing:#{relative_path}"
        end
      end)

    (module_part <> "||" <> config_part)
    |> then(&:erlang.md5/1)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
