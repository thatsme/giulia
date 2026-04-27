defmodule Giulia.Enrichment.Consumer do
  @moduledoc """
  Shared cap + attachment helpers for endpoints that surface
  enrichment findings inline in their responses (`pre_impact_check`,
  `dead_code`, future: `heatmap`).

  Two operations:

    * `attach/3` — fetches per-MFA findings via `Reader.fetch_for_mfa/2`
      for each entry and attaches them as `:enrichments`. Drops
      severities listed in the `drop_severities` config and caps
      warnings per entry per the `per_caller_warning_cap` config.
      Errors are always uncapped — they're real bugs and the cap must
      never hide one.

    * `apply_response_cap/1` — flattens findings across the entry list,
      caps the total at `per_response_cap` deduplicated by
      `{check, severity}` so a single check that fires on N entries
      collapses to one entry referencing all affected MFAs in
      `affected_mfas: [...]`. When the cap fires, per-entry
      `:enrichments` are cleared and a project-wide
      `:enrichments_summary` is attached to the first entry.

  Defaults live in `priv/config/scoring.json` under `enrichments`.
  """

  alias Giulia.Enrichment.Reader

  @type entry :: %{required(:mfa) => String.t(), optional(any()) => any()}

  @doc """
  Attach `:enrichments` to each entry. The third arg is an optional
  override for the cap config (used by tests); defaults to reading
  `Giulia.Knowledge.ScoringConfig.enrichments/0` once.
  """
  @spec attach([entry()], String.t()) :: [entry()]
  def attach(entries, project_path) when is_list(entries) and is_binary(project_path) do
    cfg = Giulia.Knowledge.ScoringConfig.enrichments()
    attach(entries, project_path, cfg)
  end

  @spec attach([entry()], String.t(), map()) :: [entry()]
  def attach(entries, project_path, cfg) do
    drop = cfg |> Map.get(:drop_severities, [:info]) |> Enum.map(&normalize_severity/1)
    warning_cap = Map.get(cfg, :per_caller_warning_cap, 3)

    Enum.map(entries, fn entry ->
      raw = Reader.fetch_for_mfa(project_path, entry.mfa)

      filtered =
        Enum.into(raw, %{}, fn {tool, findings} ->
          {tool, cap_per_entry(findings, drop, warning_cap)}
        end)

      Map.put(entry, :enrichments, filtered)
    end)
  end

  @doc """
  Enforce the per-response cap. When the global finding count would
  exceed the cap, replaces every entry's per-`:enrichments` with `%{}`
  and attaches a project-wide capped summary to the first entry.
  """
  @spec apply_response_cap([entry()]) :: [entry()]
  def apply_response_cap(entries) when is_list(entries) do
    cfg = Giulia.Knowledge.ScoringConfig.enrichments()
    apply_response_cap(entries, cfg)
  end

  @spec apply_response_cap([entry()], map()) :: [entry()]
  def apply_response_cap(entries, cfg) do
    cap = Map.get(cfg, :per_response_cap, 30)
    {flat_errors, flat_warnings} = collect_findings(entries)

    kept = flat_errors ++ Enum.take(flat_warnings, max(cap - length(flat_errors), 0))

    if length(kept) == length(flat_errors) + length(flat_warnings) do
      entries
    else
      capped_summary = build_capped_summary(kept)

      cleared = Enum.map(entries, fn entry -> Map.put(entry, :enrichments, %{}) end)

      case cleared do
        [] -> []
        [first | rest] -> [Map.put(first, :enrichments_summary, capped_summary) | rest]
      end
    end
  end

  # --- Internal ---

  defp cap_per_entry(findings, drop_severities, warning_cap) do
    findings
    |> Enum.reject(fn f -> Map.get(f, :severity) in drop_severities end)
    |> Enum.split_with(fn f -> Map.get(f, :severity) == :error end)
    |> then(fn {errors, rest} ->
      warnings = Enum.take(rest, warning_cap)
      errors ++ warnings
    end)
  end

  defp collect_findings(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      Enum.flat_map(entry.enrichments, fn {tool, findings} ->
        Enum.map(findings, fn f -> {tool, entry.mfa, f} end)
      end)
    end)
    |> Enum.split_with(fn {_tool, _mfa, f} -> Map.get(f, :severity) == :error end)
  end

  defp build_capped_summary(triples) do
    triples
    |> Enum.group_by(
      fn {tool, _mfa, f} -> {tool, Map.get(f, :check), Map.get(f, :severity)} end,
      fn {_tool, mfa, _f} -> mfa end
    )
    |> Enum.map(fn {{tool, check, sev}, mfas} ->
      %{tool: tool, check: check, severity: sev, affected_mfas: Enum.uniq(mfas)}
    end)
  end

  defp normalize_severity(s) when is_atom(s), do: s
  defp normalize_severity(s) when is_binary(s), do: String.to_atom(s)
  defp normalize_severity(_), do: :info
end
