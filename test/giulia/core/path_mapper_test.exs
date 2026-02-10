defmodule Giulia.Core.PathMapperTest do
  @moduledoc """
  Path translation tests for PathMapper.

  PathMapper handles host↔container path translation. These tests prove:

  1. Host paths (Windows) are correctly mapped to container paths (/projects/...)
  2. Container paths are correctly mapped back to host paths
  3. Slash normalization works for Windows backslashes
  4. LM Studio URL resolution follows env var priority
  5. Legacy fallback mappings work
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
        if original, do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
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
        if original, do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
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
        if original, do: System.put_env("GIULIA_IN_CONTAINER", original),
        else: System.delete_env("GIULIA_IN_CONTAINER")
      end)

      assert PathMapper.in_container?()
    end

    test "env var must be exactly 'true'" do
      original = System.get_env("GIULIA_IN_CONTAINER")
      System.put_env("GIULIA_IN_CONTAINER", "false")

      on_exit(fn ->
        if original, do: System.put_env("GIULIA_IN_CONTAINER", original),
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
        if original, do: System.put_env("GIULIA_LM_STUDIO_URL", original),
        else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_base_url() == "http://192.168.1.52:1234"
    end

    test "strips trailing slash from env var" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234/")

      on_exit(fn ->
        if original, do: System.put_env("GIULIA_LM_STUDIO_URL", original),
        else: System.delete_env("GIULIA_LM_STUDIO_URL")
      end)

      assert PathMapper.lm_studio_base_url() == "http://192.168.1.52:1234"
    end

    test "extracts base URL from full chat completions URL" do
      original = System.get_env("GIULIA_LM_STUDIO_URL")
      System.put_env("GIULIA_LM_STUDIO_URL", "http://192.168.1.52:1234/v1/chat/completions")

      on_exit(fn ->
        if original, do: System.put_env("GIULIA_LM_STUDIO_URL", original),
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
        if original, do: System.put_env("GIULIA_LM_STUDIO_URL", original),
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
        if original, do: System.put_env("GIULIA_LM_STUDIO_URL", original),
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
        if original, do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original),
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
  # Section 7: Legacy Fallback Mappings
  # ============================================================================

  describe "to_container/1 — legacy fallback" do
    setup do
      # Remove env var so legacy fallback kicks in
      original = System.get_env("GIULIA_HOST_PROJECTS_PATH")
      original_config = Application.get_env(:giulia, :host_projects_path)
      System.delete_env("GIULIA_HOST_PROJECTS_PATH")
      Application.delete_env(:giulia, :host_projects_path)

      on_exit(fn ->
        if original, do: System.put_env("GIULIA_HOST_PROJECTS_PATH", original)
        if original_config, do: Application.put_env(:giulia, :host_projects_path, original_config)
      end)
      :ok
    end

    test "falls back to C:/Users → /users mapping" do
      result = PathMapper.to_container("C:/Users/alessio/project/file.ex")
      assert result == "/users/alessio/project/file.ex"
    end

    test "falls back to /home → /home mapping" do
      result = PathMapper.to_container("/home/user/project/file.ex")
      assert result == "/home/user/project/file.ex"
    end

    test "returns path unchanged when no mapping matches" do
      result = PathMapper.to_container("/some/random/path.ex")
      assert result == "/some/random/path.ex"
    end
  end
end
