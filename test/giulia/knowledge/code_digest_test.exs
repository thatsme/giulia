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
end
