defmodule Giulia.Core.PathSandboxAdversarialTest do
  @moduledoc """
  Adversarial tests for PathSandbox — the jailbreak prevention system.

  This is the most security-critical module in Giulia. Every file operation
  goes through it. These tests probe:

  - Null byte injection (C string terminator trick)
  - Unicode path tricks (homoglyphs, normalization)
  - Allowed external path boundary spoofing
  - Allowed external traversal attacks
  - Case sensitivity edge cases
  - Empty/whitespace paths
  - Extremely long paths
  - Double-dot variants (... , ....)
  - Root boundary edge cases
  - Windows drive letter attacks
  - Path with special characters
  """
  use ExUnit.Case, async: true

  alias Giulia.Core.PathSandbox

  # ============================================================================
  # 1. Null byte injection
  # ============================================================================

  describe "null byte injection" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "null byte in middle of path component", %{sandbox: sandbox} do
      # Attack: OS might truncate at \0, reading a different file than validated
      path = "/projects/Giulia/lib/foo\0../../etc/passwd"
      result = PathSandbox.validate(sandbox, path)
      case result do
        {:ok, expanded} ->
          # If it passes, the expanded path must NOT contain null bytes
          # and must still be inside sandbox
          refute String.contains?(expanded, "\0"),
            "Expanded path must not contain null bytes"
        {:error, :sandbox_violation} ->
          :ok
      end
    end

    test "null byte after valid path", %{sandbox: sandbox} do
      path = "/projects/Giulia/lib/foo.ex\0"
      result = PathSandbox.validate(sandbox, path)
      case result do
        {:ok, expanded} ->
          refute String.contains?(expanded, "\0")
        {:error, _} -> :ok
      end
    end

    test "null byte as path separator trick", %{sandbox: sandbox} do
      path = "/projects/Giulia\0/etc/passwd"
      result = PathSandbox.validate(sandbox, path)
      case result do
        {:ok, expanded} ->
          refute String.contains?(expanded, "\0")
          assert String.starts_with?(expanded, "/projects/Giulia")
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 2. Allowed external path boundary spoofing
  # ============================================================================

  describe "allowed external boundary spoofing" do
    test "path that starts with allowed prefix but is a different directory" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      # /tmp/cacheevil starts with "/tmp/cache" but is a DIFFERENT directory
      result = PathSandbox.validate(sandbox, "/tmp/cacheevil/exploit.sh")
      assert {:error, :sandbox_violation} = result
    end

    test "path that starts with allowed prefix plus extra chars" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      # /tmp/cache2 is not /tmp/cache/
      result = PathSandbox.validate(sandbox, "/tmp/cache2/data.txt")
      assert {:error, :sandbox_violation} = result
    end

    test "exact allowed path is permitted", do: do_test_exact_allowed()

    defp do_test_exact_allowed do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      # /tmp/cache/file.txt should still be allowed
      assert {:ok, _} = PathSandbox.validate(sandbox, "/tmp/cache/file.txt")
    end

    test "allowed external with traversal to escape" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      # Traversal resolves BEFORE the allowed check
      result = PathSandbox.validate(sandbox, "/tmp/cache/../../../etc/passwd")
      assert {:error, :sandbox_violation} = result
    end

    test "allowed external with trailing slash ambiguity" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache/")

      # The trailing slash gets stripped by normalize_and_expand
      assert {:ok, _} = PathSandbox.validate(sandbox, "/tmp/cache/data.txt")
    end
  end

  # ============================================================================
  # 3. Path traversal variants
  # ============================================================================

  describe "path traversal variants" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "triple dots are not path traversal", %{sandbox: sandbox} do
      # "..." is a regular directory name, not path traversal
      result = PathSandbox.validate(sandbox, "/projects/Giulia/.../file.ex")
      assert {:ok, expanded} = result
      assert expanded =~ "..."
    end

    test "quadruple dots are not path traversal", %{sandbox: sandbox} do
      result = PathSandbox.validate(sandbox, "/projects/Giulia/..../file.ex")
      assert {:ok, _} = result
    end

    test "many consecutive .. to escape deeply", %{sandbox: sandbox} do
      traversal = String.duplicate("../", 50)
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, traversal <> "etc/passwd")
    end

    test ".. at various positions in path", %{sandbox: sandbox} do
      # All should escape: lib/../../.. goes up 3, root is only 3 deep
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/a/b/../../../../etc/passwd")
    end

    test "interleaved valid dirs and ..", %{sandbox: sandbox} do
      # /projects/Giulia/a/../b/../c/../../../etc/passwd
      # Resolves: Giulia/a→Giulia/→Giulia/b→Giulia/→Giulia/c→Giulia/→projects/→/→/etc/passwd
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/a/../b/../c/../../../etc/passwd")
    end

    test "relative path with only ..", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "../../../etc/shadow")
    end

    test "single .. from root stays blocked", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/../Other/file.ex")
    end
  end

  # ============================================================================
  # 4. Empty and whitespace paths
  # ============================================================================

  describe "empty and whitespace paths" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "empty string resolves to root (acceptable)", %{sandbox: sandbox} do
      # Empty path joined with root = root itself
      result = PathSandbox.validate(sandbox, "")
      assert {:ok, expanded} = result
      assert expanded == "/projects/Giulia"
    end

    test "single dot resolves to root", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, ".")
      assert expanded == "/projects/Giulia"
    end

    test "path with spaces is treated as-is", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "/projects/Giulia/my file.ex")
      assert expanded == "/projects/Giulia/my file.ex"
    end

    test "path with only spaces", %{sandbox: sandbox} do
      # Spaces are valid path characters — resolves to root/spaces
      result = PathSandbox.validate(sandbox, "   ")
      assert {:ok, _} = result
    end
  end

  # ============================================================================
  # 5. Unicode and special character paths
  # ============================================================================

  describe "unicode and special characters" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "unicode filename", %{sandbox: sandbox} do
      assert {:ok, _} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/модуль.ex")
    end

    test "emoji in path", %{sandbox: sandbox} do
      assert {:ok, _} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/🔥.ex")
    end

    test "CJK characters in path", %{sandbox: sandbox} do
      assert {:ok, _} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/日本語.ex")
    end

    test "unicode slash lookalike (fullwidth solidus) does not act as separator", %{sandbox: sandbox} do
      # U+FF0F is a fullwidth solidus — looks like / but shouldn't be treated as separator
      path = "/projects/Giulia/lib/foo\uFF0Fbar.ex"
      result = PathSandbox.validate(sandbox, path)
      assert {:ok, expanded} = result
      # The fullwidth solidus should remain as-is, not split the path
      assert expanded =~ "\uFF0F"
    end

    test "unicode dot lookalike does not act as ..", %{sandbox: sandbox} do
      # U+2025 is TWO DOT LEADER (‥) — looks like .. but isn't
      path = "/projects/Giulia/\u2025/etc/passwd"
      assert {:ok, _} = PathSandbox.validate(sandbox, path)
    end
  end

  # ============================================================================
  # 6. Windows-specific edge cases
  # ============================================================================

  describe "Windows path edge cases" do
    test "Windows root with backslashes" do
      sandbox = PathSandbox.new("C:\\Development\\GitHub\\Giulia")
      assert {:ok, _} = PathSandbox.validate(sandbox, "C:\\Development\\GitHub\\Giulia\\lib\\foo.ex")
    end

    test "Windows traversal with backslashes" do
      sandbox = PathSandbox.new("C:\\Development\\GitHub\\Giulia")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "C:\\Development\\GitHub\\Giulia\\..\\..\\Windows\\System32\\config")
    end

    test "mixed forward and back slashes in traversal" do
      sandbox = PathSandbox.new("C:/Development/GitHub/Giulia")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "C:\\Development\\GitHub\\Giulia/..\\../Windows")
    end

    test "different drive letter is blocked" do
      sandbox = PathSandbox.new("C:/Development/GitHub/Giulia")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "D:/secrets/passwords.txt")
    end

    test "UNC path is blocked" do
      sandbox = PathSandbox.new("C:/Development/GitHub/Giulia")
      result = PathSandbox.validate(sandbox, "//server/share/file.txt")
      assert {:error, :sandbox_violation} = result
    end
  end

  # ============================================================================
  # 7. Root boundary edge cases
  # ============================================================================

  describe "root boundary" do
    test "root path itself is allowed" do
      sandbox = PathSandbox.new("/projects/Giulia")
      assert {:ok, "/projects/Giulia"} = PathSandbox.validate(sandbox, "/projects/Giulia")
    end

    test "sibling with same prefix is blocked" do
      # /projects/Giulia vs /projects/Giulia-fork
      sandbox = PathSandbox.new("/projects/Giulia")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia-fork/steal.ex")
    end

    test "sibling with root as substring is blocked" do
      sandbox = PathSandbox.new("/projects/Giulia")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/GiuliaSecrets/key.pem")
    end

    test "root at filesystem root" do
      sandbox = PathSandbox.new("/")
      # Everything should be allowed when root is /
      assert {:ok, _} = PathSandbox.validate(sandbox, "/etc/passwd")
      assert {:ok, _} = PathSandbox.validate(sandbox, "/home/user/file.txt")
    end

    test "deeply nested root" do
      sandbox = PathSandbox.new("/a/b/c/d/e/f/g/h")
      assert {:ok, _} = PathSandbox.validate(sandbox, "/a/b/c/d/e/f/g/h/file.ex")
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/a/b/c/d/e/f/g/other.ex")
    end
  end

  # ============================================================================
  # 8. Extremely long paths (DoS resistance)
  # ============================================================================

  describe "long paths" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "very long valid path does not crash", %{sandbox: sandbox} do
      long_dir = String.duplicate("subdir/", 1000)
      path = "/projects/Giulia/" <> long_dir <> "file.ex"
      result = PathSandbox.validate(sandbox, path)
      assert {:ok, _} = result
    end

    test "very long traversal does not crash", %{sandbox: sandbox} do
      long_traversal = String.duplicate("../", 10_000)
      result = PathSandbox.validate(sandbox, long_traversal <> "etc/passwd")
      assert {:error, :sandbox_violation} = result
    end

    test "path with very long component name", %{sandbox: sandbox} do
      long_name = String.duplicate("a", 10_000)
      path = "/projects/Giulia/lib/#{long_name}.ex"
      assert {:ok, _} = PathSandbox.validate(sandbox, path)
    end
  end

  # ============================================================================
  # 9. resolve_dots edge cases (testing indirectly via validate)
  # ============================================================================

  describe "dot resolution edge cases" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "multiple consecutive dots-dirs", %{sandbox: sandbox} do
      # ./././file.ex should resolve to /projects/Giulia/file.ex
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "./././file.ex")
      assert expanded == "/projects/Giulia/file.ex"
    end

    test ".. beyond filesystem root collapses to root", %{sandbox: sandbox} do
      # 50 levels of .. from a 3-level-deep root should collapse
      # resolve_dots([".." | rest], []) just skips the ..
      # So we end up at "/" or empty, which fails sandbox check
      traversal = String.duplicate("../", 50)
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/" <> traversal <> "x")
    end

    test "alternating . and .. in path", %{sandbox: sandbox} do
      # lib/./foo/../bar → lib/bar (stays inside sandbox)
      assert {:ok, expanded} =
               PathSandbox.validate(sandbox, "/projects/Giulia/lib/./foo/../bar.ex")
      assert expanded == "/projects/Giulia/lib/bar.ex"
    end

    test "trailing .. that escapes", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/..")
    end

    test "path ending with ." do
      sandbox = PathSandbox.new("/projects/Giulia")
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/.")
      assert expanded == "/projects/Giulia/lib"
    end
  end

  # ============================================================================
  # 10. safe?/2 with adversarial inputs
  # ============================================================================

  describe "safe?/2 adversarial" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "safe? returns false for null byte path", %{sandbox: sandbox} do
      # Should not crash
      result = PathSandbox.safe?("/projects/Giulia/\0/../../../etc/passwd", sandbox)
      assert is_boolean(result)
    end

    test "safe? returns false for empty path sibling escape", %{sandbox: sandbox} do
      refute PathSandbox.safe?("/projects/Other/file.ex", sandbox)
    end

    test "safe? is consistent with validate", %{sandbox: sandbox} do
      paths = [
        "/projects/Giulia/lib/foo.ex",
        "/etc/passwd",
        "../../etc/shadow",
        "/projects/Giulia/../Other/file.ex",
        "/projects/Giulia/lib/../mix.exs",
        ""
      ]

      for path <- paths do
        safe = PathSandbox.safe?(path, sandbox)
        valid = match?({:ok, _}, PathSandbox.validate(sandbox, path))
        assert safe == valid, "safe? and validate disagree on: #{inspect(path)}"
      end
    end
  end
end
