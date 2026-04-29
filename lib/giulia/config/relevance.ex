defmodule Giulia.Config.Relevance do
  @moduledoc """
  Relevance bucket definitions for noisy listing endpoints.

  Loaded once at first call from `priv/config/relevance.json` and cached
  in `:persistent_term`. Reads are free; writes only happen on the first
  call after boot.

  Editing the JSON and restarting the daemon picks up new buckets — no
  recompile, no per-project opt-in. Companion of `ScoringConfig`,
  `DispatchPatterns`, `DispatchInvariants`, `ScanConfig` — same
  persistence pattern, same loader shape.

  Public API:

    - `dead_code_categories/1` — for `?relevance=high|medium`, returns
      the set of dead-code `:category` atoms to retain. Returns `:all`
      (sentinel) for `"all"` or unrecognised values, signalling no filter.

    - `convention_severities/1` — for `?relevance=high|medium`, returns
      the set of severity strings to retain (`MapSet.t(String.t())`).
      Returns `:all` for `"all"` or unrecognised values.

    - `duplicate_threshold/2` — for `?relevance=high|medium`, returns
      `max(supplied_threshold, bucket_threshold)` so relevance can only
      tighten, never loosen. Returns `supplied_threshold` for `"all"` or
      unrecognised values.

  Unrecognised relevance values silently degrade to `"all"` (no filter)
  per design. The query-parameter parser at the protocol boundary may
  log a warning if it wishes; this module is policy-neutral.
  """

  @persistent_term_key {__MODULE__, :config}

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

  @spec reload() :: map()
  def reload do
    cfg = load()
    :persistent_term.put(@persistent_term_key, cfg)
    cfg
  end

  @spec dead_code_categories(String.t() | nil) :: :all | MapSet.t(atom())
  def dead_code_categories(bucket) when bucket in ["high", "medium"] do
    current().dead_code |> Map.fetch!(bucket) |> MapSet.new()
  end

  def dead_code_categories(_), do: :all

  @spec convention_severities(String.t() | nil) :: :all | MapSet.t(String.t())
  def convention_severities(bucket) when bucket in ["high", "medium"] do
    current().conventions |> Map.fetch!(bucket) |> MapSet.new()
  end

  def convention_severities(_), do: :all

  @spec duplicate_threshold(String.t() | nil, float()) :: float()
  def duplicate_threshold(bucket, supplied_threshold)
      when bucket in ["high", "medium"] and is_number(supplied_threshold) do
    bucket_threshold = current().duplicates |> Map.fetch!(bucket)
    max(supplied_threshold, bucket_threshold)
  end

  def duplicate_threshold(_, supplied_threshold), do: supplied_threshold

  defp load do
    path = Path.join(:code.priv_dir(:giulia), "config/relevance.json")

    case File.read(path) do
      {:ok, body} ->
        raw = Jason.decode!(body)

        %{
          dead_code: %{
            "high" => decode_atoms!(raw, "dead_code", "high"),
            "medium" => decode_atoms!(raw, "dead_code", "medium")
          },
          conventions: %{
            "high" => fetch_strings!(raw, "conventions", "high"),
            "medium" => fetch_strings!(raw, "conventions", "medium")
          },
          duplicates: %{
            "high" => fetch_number!(raw, "duplicates", "high"),
            "medium" => fetch_number!(raw, "duplicates", "medium")
          }
        }

      {:error, reason} ->
        raise "Relevance: cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp decode_atoms!(raw, key, bucket) do
    list = raw |> Map.fetch!(key) |> Map.fetch!(bucket)

    unless Enum.all?(list, &is_binary/1) do
      raise "Relevance: #{key}.#{bucket} must be a list of strings, got #{inspect(list)}"
    end

    Enum.map(list, &String.to_atom/1)
  end

  defp fetch_strings!(raw, key, bucket) do
    list = raw |> Map.fetch!(key) |> Map.fetch!(bucket)

    unless Enum.all?(list, &is_binary/1) do
      raise "Relevance: #{key}.#{bucket} must be a list of strings, got #{inspect(list)}"
    end

    list
  end

  defp fetch_number!(raw, key, bucket) do
    val = raw |> Map.fetch!(key) |> Map.fetch!(bucket)

    unless is_number(val) do
      raise "Relevance: #{key}.#{bucket} must be a number, got #{inspect(val)}"
    end

    val * 1.0
  end
end
