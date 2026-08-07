defmodule Giulia.Core.PathMapperTest do
  @moduledoc """
  Path translation tests for PathMapper.

  PathMapper handles host↔container path translation. These tests prove:

  1. Host paths are correctly mapped to container paths (/projects/...)
  2. Container paths are correctly mapped back to host paths
  3. Slash normalization works for Windows backslashes
  4. LM Studio URL resolution follows env var priority
  5. Mappings come only from configuration, so Windows and macOS hosts differ
     in their settings and not in Giulia's behaviour
  """
  use ExUnit.Case, async: false

  # async: false because we modify env vars and Application config

  alias Giulia.Core.PathMapper

  # ============================================================================
  # Section 1: to_container/1 — Host → Container Path Translation
  # ============================================================================

  describe "to_container/1" do
    setup do
      # Save and set env for test
      original = System.get_env("GIULIA_HOST_PROJECTS_PATH")
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "C:/Development/GitHub")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
          else: System.delete_env("GIULIA_HOST_PROJECTS_PATH")
      end)

      :ok
    end

    test "maps host path to container path" do
      result = PathMapper.to_container("C:/Development/GitHub/Giulia/lib/giulia.ex")
      assert result == "/projects/Giulia/lib/giulia.ex"
    end

    test "normalizes Windows backslashes" do
      result = PathMapper.to_container("C:\\Development\\GitHub\\Giulia\\mix.exs")
      assert result == "/projects/Giulia/mix.exs"
    end

    test "handles case-insensitive drive letter" do
      result = PathMapper.to_container("c:/Development/GitHub/Giulia/mix.exs")
      assert result == "/projects/Giulia/mix.exs"
    end

    test "preserves path suffix after prefix swap" do
      result = PathMapper.to_container("C:/Development/GitHub/MyApp/lib/deep/nested/file.ex")
      assert result == "/projects/MyApp/lib/deep/nested/file.ex"
    end
  end

  # ============================================================================
  # Section 2: to_host/1 — Container → Host Path Translation
  # ============================================================================

  describe "to_host/1" do
    setup do
      original = System.get_env("GIULIA_HOST_PROJECTS_PATH")
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "C:/Development/GitHub")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
          else: System.delete_env("GIULIA_HOST_PROJECTS_PATH")
      end)

      :ok
    end

    test "maps container path back to host path" do
      result = PathMapper.to_host("/projects/Giulia/lib/giulia.ex")
      assert result == "C:/Development/GitHub/Giulia/lib/giulia.ex"
    end

    test "returns container path unchanged when no prefix match" do
      result = PathMapper.to_host("/tmp/some_file.txt")
      assert result == "/tmp/some_file.txt"
    end

    test "round-trips correctly (host → container → host)" do
      original = "C:/Development/GitHub/Giulia/lib/giulia.ex"
      round_tripped = original |> PathMapper.to_container() |> PathMapper.to_host()
      assert round_tripped == original
    end
  end

  # ============================================================================
  # Section 3: resolve_path/1 — Smart Path Resolution
  # ============================================================================

  describe "resolve_path/1" do
    test "outside container, returns path unchanged" do
      # When not in container, resolve_path is identity
      original_env = System.get_env("GIULIA_IN_CONTAINER")
      System.delete_env("GIULIA_IN_CONTAINER")

      on_exit(fn ->
        if original_env, do: System.put_env("GIULIA_IN_CONTAINER", original_env)
      end)

      # Outside Docker (no /.dockerenv, no env var) it returns path as-is
      # This test only works reliably outside Docker
      unless PathMapper.in_container?() do
        result = PathMapper.resolve_path("C:/Development/GitHub/Giulia")
        assert result == "C:/Development/GitHub/Giulia"
      end
    end
  end

  # ============================================================================
  # Section 4: in_container?/0 — Docker Detection
  # ============================================================================

  describe "in_container?/0" do
    test "returns true when GIULIA_IN_CONTAINER is set" do
      original = System.get_env("GIULIA_IN_CONTAINER")
      System.put_env("GIULIA_IN_CONTAINER", "true")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_IN_CONTAINER", original),
          else: System.delete_env("GIULIA_IN_CONTAINER")
      end)

      assert PathMapper.in_container?()
    end

    test "env var must be exactly 'true'" do
      original = System.get_env("GIULIA_IN_CONTAINER")
      System.put_env("GIULIA_IN_CONTAINER", "false")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_IN_CONTAINER", original),
          else: System.delete_env("GIULIA_IN_CONTAINER")
      end)

      # "false" != "true", so unless /.dockerenv exists, this returns false
      unless File.exists?("/.dockerenv") or File.exists?("/run/.containerenv") do
        refute PathMapper.in_container?()
      end
    end
  end

  # ============================================================================
  # Section 5: LM Studio URL Resolution
  # ============================================================================

  describe "lm_studio_base_url/0" do
    test "uses GIULIA_LM_STUDIO_URL env var when set" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_LM_STUDIO_URL", original),
          else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_base_url() == "http://192.168.1.52:1234"
    end

    test "strips trailing slash from env var" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234/")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_LM_STUDIO_URL", original),
          else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_base_url() == "http://192.168.1.52:1234"
    end

    test "extracts base URL from full chat completions URL" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234/v1/chat/completions")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_LM_STUDIO_URL", original),
          else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_base_url() == "http://192.168.1.52:1234"
    end
  end

  describe "lm_studio_url/0" do
    test "appends /v1/chat/completions to base URL" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_LM_STUDIO_URL", original),
          else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_url() == "http://192.168.1.52:1234/v1/chat/completions"
    end
  end

  describe "lm_studio_models_url/0" do
    test "appends /v1/models to base URL" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_LM_STUDIO_URL", original),
          else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_models_url() == "http://192.168.1.52:1234/v1/models"
    end
  end

  # ============================================================================
  # Section 6: list_mappings/0 and add_mapping/2
  # ============================================================================

  describe "list_mappings/0" do
    test "returns mapping when host prefix is configured" do
      original = System.get_env("GIULIA_HOST_PROJECTS_PATH")
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "C:/Development/GitHub")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
          else: System.delete_env("GIULIA_HOST_PROJECTS_PATH")
      end)

      mappings = PathMapper.list_mappings()
      assert [{"C:/Development/GitHub", "/projects"}] = mappings
    end

    test "returns empty list when no prefix configured" do
      original = System.get_env("GIULIA_HOST_PROJECTS_PATH")
      original_config = Application.get_env(:giulia, :host_projects_path)
      System.delete_env("GIULIA_HOST_PROJECTS_PATH")
      Application.delete_env(:giulia, :host_projects_path)

      on_exit(fn ->
        if original, do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original)
        if original_config, do: Application.put_env(:giulia, :host_projects_path, original_config)
      end)

      assert PathMapper.list_mappings() == []
    end
  end

  # ============================================================================
  # Section 7: Unmapped Paths
  #
  # No host path is compiled into PathMapper, so a path the environment does
  # not describe must survive untouched. The predecessor shipped a hardcoded
  # table that rewrote `/Users/...` to `/users/...` — a directory that no
  # compose file mounts — which silently broke every macOS host path that
  # missed the configured prefix.
  # ============================================================================

  describe "to_container/1 — no mappings configured" do
    setup :clear_mapping_env

    test "returns an unrecognised path unchanged" do
      assert PathMapper.to_container("/some/random/path.ex") == "/some/random/path.ex"
    end

    test "does not invent a mapping for a macOS home path" do
      assert PathMapper.to_container("/Users/alex/dev/app/lib/app.ex") ==
               "/Users/alex/dev/app/lib/app.ex"
    end

    test "does not invent a mapping for a Windows user path" do
      assert PathMapper.to_container("C:/Users/alex/dev/app.ex") == "C:/Users/alex/dev/app.ex"
    end

    test "list_mappings/0 is empty" do
      assert PathMapper.list_mappings() == []
    end
  end

  # ============================================================================
  # Section 8: Cross-Platform Behaviour
  #
  # The same image runs under Docker Desktop on Windows and OrbStack on macOS.
  # These tests pin the platform-sensitive rules: case handling, segment
  # boundaries, and longest-prefix precedence.
  # ============================================================================

  describe "to_container/1 — macOS host prefix" do
    setup do
      clear_mapping_env(%{})
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "/Users/alex/dev")
      :ok
    end

    test "maps a POSIX host path to the container mount" do
      assert PathMapper.to_container("/Users/alex/dev/Giulia/mix.exs") ==
               "/projects/Giulia/mix.exs"
    end

    test "round-trips host → container → host" do
      original = "/Users/alex/dev/Giulia/lib/giulia.ex"
      assert original |> PathMapper.to_container() |> PathMapper.to_host() == original
    end

    # A Linux container filesystem distinguishes /Users from /users. Matching
    # case-insensitively here would rewrite the path to a directory that is
    # not mounted, which is exactly how the old hardcoded table failed.
    test "does not match a POSIX prefix that differs only by case" do
      assert PathMapper.to_container("/users/alex/dev/Giulia/mix.exs") ==
               "/users/alex/dev/Giulia/mix.exs"
    end

    test "does not match a sibling directory sharing the prefix" do
      assert PathMapper.to_container("/Users/alex/devil/secret.ex") ==
               "/Users/alex/devil/secret.ex"
    end

    test "maps the prefix itself to the bare mount point" do
      assert PathMapper.to_container("/Users/alex/dev") == "/projects"
    end
  end

  describe "to_container/1 — Windows host prefix" do
    setup do
      clear_mapping_env(%{})
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "D:/Development/GitHub")
      :ok
    end

    # Windows paths are case-insensitive, so a drive letter in either case must
    # resolve. This stays permissive only for prefixes starting `X:`.
    test "matches a drive letter in either case" do
      assert PathMapper.to_container("d:/Development/GitHub/Giulia/mix.exs") ==
               "/projects/Giulia/mix.exs"
    end

    test "normalizes backslashes" do
      assert PathMapper.to_container("D:\\Development\\GitHub\\Giulia\\mix.exs") ==
               "/projects/Giulia/mix.exs"
    end

    test "does not match a sibling directory sharing the prefix" do
      assert PathMapper.to_container("D:/Development/GitHubOld/x.ex") ==
               "D:/Development/GitHubOld/x.ex"
    end
  end

  # ============================================================================
  # Section 9: GIULIA_PATH_MAPPING
  # ============================================================================

  describe "GIULIA_PATH_MAPPING" do
    setup :clear_mapping_env

    test "parses a single host=container pair" do
      System.put_env("GIULIA_PATH_MAPPING", "/srv/code=/projects")
      assert PathMapper.to_container("/srv/code/app/lib/app.ex") == "/projects/app/lib/app.ex"
    end

    test "parses several semicolon-separated pairs" do
      System.put_env("GIULIA_PATH_MAPPING", "/srv/code=/projects;/opt/vendor=/vendor")
      assert PathMapper.to_container("/opt/vendor/dep/x.ex") == "/vendor/dep/x.ex"
      assert PathMapper.to_container("/srv/code/app.ex") == "/projects/app.ex"
    end

    test "the longest matching prefix wins regardless of declaration order" do
      System.put_env("GIULIA_PATH_MAPPING", "/srv=/short;/srv/code/deep=/deep")
      assert PathMapper.to_container("/srv/code/deep/x.ex") == "/deep/x.ex"
    end

    test "an entry with no separator is ignored rather than crashing" do
      System.put_env("GIULIA_PATH_MAPPING", "garbage-no-equals")
      assert PathMapper.list_mappings() == []
      assert PathMapper.to_container("/srv/code/app.ex") == "/srv/code/app.ex"
    end

    test "blank sides are dropped" do
      System.put_env("GIULIA_PATH_MAPPING", "=/projects;/srv/code=")
      assert PathMapper.list_mappings() == []
    end

    test "an empty value contributes no mappings" do
      System.put_env("GIULIA_PATH_MAPPING", "")
      assert PathMapper.list_mappings() == []
    end

    test "coexists with GIULIA_HOST_PROJECTS_PATH" do
      System.put_env("GIULIA_PATH_MAPPING", "/opt/vendor=/vendor")
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "/Users/alex/dev")

      assert PathMapper.to_container("/opt/vendor/dep.ex") == "/vendor/dep.ex"
      assert PathMapper.to_container("/Users/alex/dev/app.ex") == "/projects/app.ex"
    end
  end

  # ============================================================================
  # Section 10: diagnostics/0
  # ============================================================================

  describe "diagnostics/0" do
    setup :clear_mapping_env

    test "reports the active mappings" do
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "/Users/alex/dev")

      assert %{mappings: [%{host: "/Users/alex/dev", container: "/projects"}]} =
               PathMapper.diagnostics()
    end

    test "no warning once a mapping exists" do
      System.put_env("GIULIA_HOST_PROJECTS_PATH", "/Users/alex/dev")
      assert %{warning: nil} = PathMapper.diagnostics()
    end

    # Unmapped-in-a-container is the misconfiguration that used to surface as
    # an empty scan. It must be visible at the edge instead.
    test "warns when running in a container with nothing to translate" do
      original = System.get_env("GIULIA_IN_CONTAINER")
      System.put_env("GIULIA_IN_CONTAINER", "true")

      on_exit(fn ->
        if original,
          do: System.put_env("GIULIA_IN_CONTAINER", original),
          else: System.delete_env("GIULIA_IN_CONTAINER")
      end)

      assert %{warning: warning, in_container: true} = PathMapper.diagnostics()
      assert is_binary(warning)
      assert warning =~ "GIULIA_HOST_PROJECTS_PATH"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Clears every source of mappings and restores it afterwards, so a test sees
  # only the configuration it sets itself.
  defp clear_mapping_env(_context) do
    originals = %{
      projects: System.get_env("GIULIA_HOST_PROJECTS_PATH"),
      mapping: System.get_env("GIULIA_PATH_MAPPING"),
      config: Application.get_env(:giulia, :host_projects_path),
      runtime: Application.get_env(:giulia, :path_mappings)
    }

    System.delete_env("GIULIA_HOST_PROJECTS_PATH")
    System.delete_env("GIULIA_PATH_MAPPING")
    Application.delete_env(:giulia, :host_projects_path)
    Application.delete_env(:giulia, :path_mappings)

    on_exit(fn ->
      restore_env("GIULIA_HOST_PROJECTS_PATH", originals.projects)
      restore_env("GIULIA_PATH_MAPPING", originals.mapping)
      if originals.config, do: Application.put_env(:giulia, :host_projects_path, originals.config)
      if originals.runtime, do: Application.put_env(:giulia, :path_mappings, originals.runtime)
    end)

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
