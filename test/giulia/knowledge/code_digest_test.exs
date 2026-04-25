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
end
