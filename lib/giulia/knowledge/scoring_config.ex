defmodule Giulia.Knowledge.ScoringConfig do
  @moduledoc """
  Scoring constants for heatmap, change_risk, god_modules, and
  unprotected_hubs.

  Loaded once at first call from `priv/config/scoring.json` and cached in
  `:persistent_term`. Reads are free; writes only happen on the first
  call after boot.

  Editing the JSON and restarting the daemon picks up new values — no
  recompile, no per-project opt-in. The defaults must be valid for every
  codebase (per `feedback_zero_config_universal`); tune cautiously.

  Companion of `DispatchPatterns` and `ScanConfig` — same persistence
  pattern, same loader shape.
  """

  @persistent_term_key {__MODULE__, :config}

  @doc """
  Return the loaded scoring config. First call loads + caches; subsequent
  calls are pure persistent_term reads.
  """
  @spec current() :: map()
  def current do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        cfg = load()
        :persistent_term.put(@persistent_term_key, cfg)
        cfg

      cfg ->
        cfg
    end
  end

  @doc """
  Force-reload from disk (test/diagnostic use).
  """
  @spec reload() :: map()
  def reload do
    cfg = load()
    :persistent_term.put(@persistent_term_key, cfg)
    cfg
  end

  defp load do
    path = Path.join(:code.priv_dir(:giulia), "config/scoring.json")

    case File.read(path) do
      {:ok, body} -> Jason.decode!(body, keys: :atoms)
      {:error, reason} -> raise "ScoringConfig: cannot read #{path}: #{inspect(reason)}"
    end
  end

  # Convenience accessors. Each picks one stable path in the config tree
  # so call sites read like `ScoringConfig.heatmap_weights/0` rather than
  # threading the config map through every function.

  @doc "Heatmap weight map: %{centrality, complexity, test_coverage, coupling}."
  @spec heatmap_weights() :: map()
  def heatmap_weights, do: current().heatmap.weights

  @doc "Heatmap normalization caps + missing-test factor."
  @spec heatmap_normalization() :: map()
  def heatmap_normalization, do: current().heatmap.normalization

  @doc "Heatmap zone thresholds: %{red_min, yellow_min}."
  @spec heatmap_zones() :: map()
  def heatmap_zones, do: current().heatmap.zones

  @doc "Change-risk component weights + centrality divisor + top_n."
  @spec change_risk() :: map()
  def change_risk, do: current().change_risk

  @doc "God-module weights + top_n."
  @spec god_modules() :: map()
  def god_modules, do: current().god_modules

  @doc "Unprotected-hubs default thresholds."
  @spec unprotected_hubs() :: map()
  def unprotected_hubs, do: current().unprotected_hubs

  @doc """
  Enrichment caps for `pre_impact_check` responses.
  `%{per_caller_warning_cap, per_response_cap, drop_severities}`.
  """
  @spec enrichments() :: map()
  def enrichments,
    do:
      Map.get(current(), :enrichments, %{
        per_caller_warning_cap: 3,
        per_response_cap: 30,
        drop_severities: [:info]
      })
end
