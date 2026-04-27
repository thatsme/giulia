defmodule Giulia.Enrichment.Writer do
  @moduledoc """
  Writes enrichment findings into CubDB under the key shape
  `{:enrichment, tool_atom, project_path, target_key}` where
  `target_key` is either `"Mod.fn/N"` (function-scoped) or `"Mod"`
  (module-scoped).

  Implements **replace-on-ingest** semantics: each `replace_for/3`
  call deletes every existing key under
  `{:enrichment, tool, project, _}` and writes the new finding set
  inside a single `CubDB.transaction/2` so concurrent reads never see
  a half-deleted state.

  Provenance metadata (`tool_version`, `run_at`, per-file
  `source_digest_at_run`) is stamped on every finding before persist,
  so consumers can flag stale findings on changed files.
  """

  alias Giulia.Persistence.Store

  @type tool :: atom()
  @type project_path :: String.t()

  @doc """
  Replace every prior finding for `{tool, project_path}` with the new
  set. Provenance is stamped during this call. Returns
  `{:ok, %{written: N, replaced: M}}` where `M` is the number of prior
  keys that were deleted.
  """
  @spec replace_for(tool(), project_path(), [Giulia.Enrichment.Source.finding()]) ::
          {:ok,
           %{
             targets: non_neg_integer(),
             findings: non_neg_integer(),
             replaced: non_neg_integer()
           }}
          | {:error, term()}
  def replace_for(tool, project_path, findings)
      when is_atom(tool) and is_binary(project_path) and is_list(findings) do
    with {:ok, db} <- Store.get_db(project_path) do
      stamped = Enum.map(findings, &stamp_provenance(&1, tool, project_path))
      grouped = group_by_target(stamped, tool, project_path)

      old_keys =
        db
        |> CubDB.select(
          min_key: {:enrichment, tool, project_path, ""},
          max_key: {:enrichment, tool, project_path, <<255>>}
        )
        |> Enum.map(fn {k, _v} -> k end)

      sentinel_key = {:enrichment, tool, project_path, :__ingested__}

      :ok =
        CubDB.transaction(db, fn tx ->
          tx = Enum.reduce(old_keys, tx, &CubDB.Tx.delete(&2, &1))
          tx = Enum.reduce(grouped, tx, fn {key, vals}, acc -> CubDB.Tx.put(acc, key, vals) end)
          # Sentinel: "this {tool, project} has been ingested at least
          # once" — preserved across empty ingests so tools_ingested/1
          # distinguishes "never ran" from "ran, no findings."
          tx = CubDB.Tx.put(tx, sentinel_key, true)
          {:commit, tx, :ok}
        end)

      findings_count =
        Enum.reduce(grouped, 0, fn {_k, vals}, acc -> acc + length(vals) end)

      {:ok,
       %{
         targets: map_size(grouped),
         findings: findings_count,
         replaced: length(old_keys)
       }}
    end
  end

  # ============================================================================
  # Provenance stamping
  # ============================================================================

  defp stamp_provenance(finding, tool, project_path) do
    file =
      case finding[:scope] do
        :function -> nil_safe_file(finding)
        :module -> nil_safe_file(finding)
      end

    digest = source_digest(project_path, file)

    provenance = %{
      tool: tool,
      tool_version: tool_version(tool),
      run_at: DateTime.utc_now(),
      source_digest_at_run: digest
    }

    finding
    |> Map.put(:provenance, provenance)
    |> Map.put_new(:resolution_ambiguous, false)
  end

  defp nil_safe_file(%{file: f}) when is_binary(f), do: f
  defp nil_safe_file(_), do: nil

  defp source_digest(_project_path, nil), do: nil

  defp source_digest(project_path, file) do
    full = if Path.type(file) == :absolute, do: file, else: Path.join(project_path, file)

    case File.read(full) do
      {:ok, content} -> :erlang.md5(content) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  # Resolved at parse time per source-module convention. For Credo we
  # read the dep version from mix.lock; falls back to "unknown" when
  # the lock is unreadable. Callers may inject an explicit version
  # (tests do this) — kept simple for v1.
  defp tool_version(:credo) do
    case File.read("mix.lock") do
      {:ok, content} ->
        case Regex.run(~r/"credo":\s*\{:hex,\s*:credo,\s*"([^"]+)"/, content) do
          [_, v] -> v
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp tool_version(_), do: "unknown"

  # ============================================================================
  # Grouping
  # ============================================================================

  defp group_by_target(findings, tool, project_path) do
    findings
    |> Enum.group_by(&target_key(&1, tool, project_path))
    |> Map.new()
  end

  defp target_key(%{scope: :function, module: m, function: f, arity: a}, tool, project_path) do
    {:enrichment, tool, project_path, "#{m}.#{f}/#{a}"}
  end

  defp target_key(%{scope: :module, module: m}, tool, project_path) do
    {:enrichment, tool, project_path, m}
  end
end
