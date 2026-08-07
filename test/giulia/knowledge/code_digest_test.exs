defmodule Giulia.Knowledge.CodeDigestTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.CodeDigest

  test "current/0 returns a 12-char lowercase hex string" do
    digest = CodeDigest.current()

    assert is_binary(digest)
    assert byte_size(digest) == 12
    assert digest =~ ~r/^[0-9a-f]{12}$/
  end

  test "current/0 is stable across calls within the same VM" do
    a = CodeDigest.current()
    b = CodeDigest.current()
    c = CodeDigest.current()

    assert a == b
    assert b == c
  end

  test "recompute/0 returns the same value as current/0 when modules haven't changed" do
    current = CodeDigest.current()
    recomputed = CodeDigest.recompute()

    assert current == recomputed
  end

  test "digest changes when a tracked config file content changes" do
    # Capture the baseline.
    baseline = CodeDigest.recompute()

    # Mutate scoring.json briefly, recompute, then restore. The digest
    # should differ during the mutation and match after restoration.
    path = Path.join(:code.priv_dir(:giulia), "config/scoring.json")
    {:ok, original} = File.read(path)

    try do
      mutated = original <> "\n"
      File.write!(path, mutated)
      mutated_digest = CodeDigest.recompute()

      assert mutated_digest != baseline,
             "digest should differ when scoring.json content changes"
    after
      File.write!(path, original)
      restored = CodeDigest.recompute()

      assert restored == baseline,
             "digest should return to baseline after scoring.json is restored"
    end
  end

  # Protects the cache-invalidation contract against a config file being
  # added to priv/config/ without being added to the digest: any file whose
  # values are baked into cached graph/metric output must shift the digest,
  # or an operator edit leaves stale caches validating.
  @untracked_by_design ["relevance.json"]

  test "every config file that feeds cached output is tracked by the digest" do
    priv_config = Path.join(:code.priv_dir(:giulia), "config")

    tracked =
      priv_config
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in @untracked_by_design))

    assert tracked != [], "no config files found under #{priv_config}"

    for path <- tracked do
      assert digest_shifts?(path),
             "#{Path.basename(path)} is not tracked by CodeDigest — editing it " <>
               "would leave stale L2 caches validating against an unchanged digest"
    end
  end

  test "relevance.json is excluded from the digest by design" do
    path = Path.join(:code.priv_dir(:giulia), "config/relevance.json")

    refute digest_shifts?(path),
           "relevance.json is a read-time response filter, never baked into " <>
             "cached output — tracking it would invalidate L2 caches for nothing"
  end

  # Appends a byte to `path`, recomputes, restores, and reports whether the
  # digest moved. Raises if the restore fails to bring the digest back.
  defp digest_shifts?(path) do
    baseline = CodeDigest.recompute()
    {:ok, original} = File.read(path)

    try do
      File.write!(path, original <> "\n")
      CodeDigest.recompute() != baseline
    after
      File.write!(path, original)

      unless CodeDigest.recompute() == baseline do
        raise "failed to restore #{path} — digest did not return to baseline"
      end
    end
  end
end
