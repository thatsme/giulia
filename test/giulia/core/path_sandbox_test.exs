defmodule Giulia.Core.PathSandboxTest do
  @moduledoc """
  Security boundary tests for PathSandbox.

  PathSandbox is the jailbreak prevention system — all file operations
  MUST go through it. These tests prove:

  1. Paths inside the project root are allowed
  2. Path traversal attacks (../) are blocked
  3. Absolute paths outside root are blocked
  4. Allowed external paths work correctly
  5. Slash normalization is consistent (Windows ↔ Linux)
  """
  use ExUnit.Case, async: true

  alias Giulia.Core.PathSandbox

  # ============================================================================
  # Section 1: Sandbox Creation
  # ============================================================================

  describe "new/1" do
    test "creates sandbox with normalized root" do
      sandbox = PathSandbox.new("/projects/Giulia")
      assert sandbox.root == "/projects/Giulia"
      assert sandbox.root_parts == ["/", "projects", "Giulia"]
      assert sandbox.allowed_external == []
    end

    test "normalizes backslashes in root" do
      sandbox = PathSandbox.new("C:\\Development\\GitHub\\Giulia")
      assert sandbox.root == "C:/Development/GitHub/Giulia"
    end

    test "strips trailing slash from root" do
      sandbox = PathSandbox.new("/projects/Giulia/")
      assert sandbox.root == "/projects/Giulia"
    end

    test "accepts allowed_external option" do
      sandbox = PathSandbox.new("/projects/Giulia", allowed_external: ["/tmp/cache"])
      assert sandbox.allowed_external == ["/tmp/cache"]
    end
  end

  # ============================================================================
  # Section 2: Path Validation — Happy Path (inside sandbox)
  # ============================================================================

  describe "validate/2 — paths inside sandbox" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "allows file directly in root", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "/projects/Giulia/mix.exs")
      assert expanded == "/projects/Giulia/mix.exs"
    end

    test "allows nested file", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/giulia.ex")
      assert expanded == "/projects/Giulia/lib/giulia.ex"
    end

    test "allows deeply nested file", %{sandbox: sandbox} do
      path = "/projects/Giulia/lib/giulia/core/path_sandbox.ex"
      assert {:ok, ^path} = PathSandbox.validate(sandbox, path)
    end

    test "resolves relative path within sandbox", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "lib/giulia.ex")
      assert expanded == "/projects/Giulia/lib/giulia.ex"
    end

    test "resolves . in relative path", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "./lib/giulia.ex")
      assert expanded == "/projects/Giulia/lib/giulia.ex"
    end

    test "resolves safe .. that stays inside sandbox", %{sandbox: sandbox} do
      assert {:ok, expanded} = PathSandbox.validate(sandbox, "/projects/Giulia/lib/../mix.exs")
      assert expanded == "/projects/Giulia/mix.exs"
    end
  end

  # ============================================================================
  # Section 3: Path Validation — Sandbox Violations (SECURITY CRITICAL)
  # ============================================================================

  describe "validate/2 — sandbox violations" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "blocks path traversal to parent", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/../../etc/passwd")
    end

    test "blocks absolute path outside sandbox", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/etc/passwd")
    end

    test "blocks sibling project access", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/OtherProject/secrets.env")
    end

    test "blocks home directory access", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/home/user/.ssh/id_rsa")
    end

    test "blocks relative traversal that escapes root", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "../../etc/shadow")
    end

    test "blocks double-dot deep traversal", %{sandbox: sandbox} do
      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/projects/Giulia/lib/../../../../etc/passwd")
    end
  end

  # ============================================================================
  # Section 4: safe?/2 — Boolean convenience wrapper
  # ============================================================================

  describe "safe?/2" do
    setup do
      %{sandbox: PathSandbox.new("/projects/Giulia")}
    end

    test "returns true for safe path", %{sandbox: sandbox} do
      assert PathSandbox.safe?("/projects/Giulia/lib/giulia.ex", sandbox)
    end

    test "returns false for unsafe path", %{sandbox: sandbox} do
      refute PathSandbox.safe?("/etc/passwd", sandbox)
    end

    test "returns false for traversal attack", %{sandbox: sandbox} do
      refute PathSandbox.safe?("../../etc/passwd", sandbox)
    end
  end

  # ============================================================================
  # Section 5: Allowed External Paths
  # ============================================================================

  describe "allow_external/2" do
    test "adds external path to allowlist" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      assert {:ok, _} = PathSandbox.validate(sandbox, "/tmp/cache/some_file.txt")
    end

    test "multiple external paths can be allowed" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")
        |> PathSandbox.allow_external("/var/log/giulia")

      assert {:ok, _} = PathSandbox.validate(sandbox, "/tmp/cache/data.json")
      assert {:ok, _} = PathSandbox.validate(sandbox, "/var/log/giulia/app.log")
    end

    test "non-allowed external paths are still blocked" do
      sandbox =
        PathSandbox.new("/projects/Giulia")
        |> PathSandbox.allow_external("/tmp/cache")

      assert {:error, :sandbox_violation} =
               PathSandbox.validate(sandbox, "/etc/passwd")
    end
  end

  # ============================================================================
  # Section 6: Violation Messages
  # ============================================================================

  describe "violation_message/2" do
    test "generates human-readable security message" do
      sandbox = PathSandbox.new("/projects/Giulia")
      msg = PathSandbox.violation_message("/etc/passwd", sandbox)

      assert msg =~ "SECURITY VIOLATION"
      assert msg =~ "/etc/passwd"
      assert msg =~ "/projects/Giulia"
    end
  end

  # ============================================================================
  # Section 7: Slash Normalization Edge Cases
  # ============================================================================

  describe "slash normalization" do
    test "Windows backslashes are normalized in validation" do
      sandbox = PathSandbox.new("/projects/Giulia")

      assert {:ok, expanded} =
               PathSandbox.validate(sandbox, "/projects/Giulia\\lib\\giulia.ex")

      assert expanded == "/projects/Giulia/lib/giulia.ex"
    end

    test "mixed slashes are normalized" do
      sandbox = PathSandbox.new("/projects/Giulia")

      assert {:ok, expanded} =
               PathSandbox.validate(sandbox, "/projects/Giulia/lib\\core\\path_sandbox.ex")

      assert expanded == "/projects/Giulia/lib/core/path_sandbox.ex"
    end
  end
end
