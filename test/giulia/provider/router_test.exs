defmodule Giulia.Provider.RouterTest do
  @moduledoc """
  Tests for Provider.Router — task classification and routing.

  Only tests pure classification functions. Skips provider_available?/1
  which makes HTTP calls to LM Studio / Ollama.
  """
  use ExUnit.Case, async: true

  alias Giulia.Provider.Router

  # ============================================================================
  # route/2 — meta commands (elixir_native)
  # ============================================================================

  describe "route/2 meta commands" do
    test "slash command routes to elixir_native" do
      result = Router.route("/status", %{})
      assert result.provider == :elixir_native
      assert result.intensity == :none
    end

    test "'list modules' escalates because 'module' is a high-intensity substring" do
      # "module" is in @high_intensity_keywords, so meta_command? returns false
      result = Router.route("list modules", %{})
      assert result.provider == :cloud_sonnet
    end

    test "'show' contains substring 'how' so routes as simple task" do
      # "show" contains "how" (low-intensity keyword) — simple_task? matches
      result = Router.route("show functions", %{})
      assert result.provider == :local_3b
    end

    test "meta keyword with action verb does NOT route to native" do
      # "optimize the module" — has action verb "optimize"
      result = Router.route("optimize the module", %{})
      refute result.provider == :elixir_native
    end

    test "meta keyword with 'how' question does NOT route to native" do
      result = Router.route("how are modules connected", %{})
      refute result.provider == :elixir_native
    end
  end

  # ============================================================================
  # route/2 — simple tasks (local_3b)
  # ============================================================================

  describe "route/2 simple tasks" do
    test "short explanation routes to local_3b" do
      result = Router.route("explain this function", %{})
      assert result.provider == :local_3b
      assert result.intensity == :low
    end

    test "describe request routes to local_3b" do
      result = Router.route("describe the init function", %{})
      assert result.provider == :local_3b
    end

    test "format request routes to local_3b" do
      result = Router.route("format this code", %{})
      assert result.provider == :local_3b
    end

    test "long prompt does NOT route to local_3b even with simple keywords" do
      long_prompt = "explain " <> String.duplicate("this is a very long description ", 10)
      result = Router.route(long_prompt, %{})
      # Should not be :local_3b because prompt is > 100 chars
      refute result.intensity == :low or result.provider == :elixir_native
    end
  end

  # ============================================================================
  # route/2 — complex tasks (cloud_sonnet)
  # ============================================================================

  describe "route/2 complex tasks" do
    test "refactor routes to cloud_sonnet" do
      result = Router.route("refactor the authentication system", %{})
      assert result.provider == :cloud_sonnet
      assert result.intensity == :high
    end

    test "implement routes to cloud_sonnet" do
      result = Router.route("implement a new caching layer", %{})
      assert result.provider == :cloud_sonnet
    end

    test "fix bug routes to cloud_sonnet" do
      result = Router.route("fix the bug in login flow", %{})
      assert result.provider == :cloud_sonnet
    end

    test "debug routes to cloud_sonnet" do
      result = Router.route("debug the memory leak", %{})
      assert result.provider == :cloud_sonnet
    end

    test "'all' + large context escalates" do
      result = Router.route("update all modules", %{file_count: 25})
      assert result.provider == :cloud_sonnet
    end
  end

  # ============================================================================
  # route/2 — default routing
  # ============================================================================

  describe "route/2 default" do
    test "ambiguous prompt falls to medium_task (no Ollama = cloud)" do
      # "hello world" has no meta/low/high keywords, so medium_task? is true
      # Without Ollama, medium tasks fall to :cloud_sonnet
      result = Router.route("hello world", %{})
      assert result.provider in [:cloud_sonnet, :local_32b]
      assert result.intensity == :medium
    end

    test "pure meta-only prompt routes to native" do
      # "status" is meta keyword, no action or question substrings
      result = Router.route("status", %{})
      assert result.provider == :elixir_native
    end
  end

  # ============================================================================
  # get_provider_module/1
  # ============================================================================

  describe "get_provider_module/1" do
    test "elixir_native returns :native" do
      assert :native = Router.get_provider_module(:elixir_native)
    end

    test "local_3b returns LMStudio" do
      assert Giulia.Provider.LMStudio = Router.get_provider_module(:local_3b)
    end

    test "local_32b returns Ollama" do
      assert Giulia.Provider.Ollama = Router.get_provider_module(:local_32b)
    end

    test "cloud_sonnet returns Anthropic" do
      assert Giulia.Provider.Anthropic = Router.get_provider_module(:cloud_sonnet)
    end
  end

  # ============================================================================
  # fallback/1
  # ============================================================================

  describe "fallback/1" do
    test "local_3b falls back to cloud_sonnet" do
      assert :cloud_sonnet = Router.fallback(:local_3b)
    end

    test "local_32b falls back to cloud_sonnet" do
      assert :cloud_sonnet = Router.fallback(:local_32b)
    end

    test "cloud_sonnet falls back to local_3b" do
      assert :local_3b = Router.fallback(:cloud_sonnet)
    end

    test "elixir_native has no fallback" do
      assert nil == Router.fallback(:elixir_native)
    end
  end

  # ============================================================================
  # Classification result structure
  # ============================================================================

  describe "classification structure" do
    test "result always has provider, reason, intensity" do
      result = Router.route("test prompt", %{})
      assert Map.has_key?(result, :provider)
      assert Map.has_key?(result, :reason)
      assert Map.has_key?(result, :intensity)
      assert is_binary(result.reason)
      assert result.intensity in [:none, :low, :medium, :high]
    end
  end
end
