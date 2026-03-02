defmodule Giulia.Intelligence.PreflightTest do
  @moduledoc """
  Tests for Intelligence.Preflight — contract checklist pipeline.

  Pure functional module. Tests the pipeline structure and error handling.
  Semantic features depend on EmbeddingServing being available.
  """
  use ExUnit.Case, async: false

  alias Giulia.Intelligence.Preflight

  @test_path "/projects/Giulia"

  describe "run/3 basic contract" do
    test "returns {:ok, map()} for a valid prompt and path" do
      assert {:ok, result} = Preflight.run("refactor the registry", @test_path)
      assert is_map(result)
    end

    test "result contains required top-level keys" do
      {:ok, result} = Preflight.run("test prompt", @test_path)

      assert Map.has_key?(result, :prompt)
      assert Map.has_key?(result, :project_path)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :semantic_available)
      assert Map.has_key?(result, :modules)
      assert Map.has_key?(result, :summary)
      assert Map.has_key?(result, :suggested_tools)
    end

    test "prompt is echoed back in result" do
      {:ok, result} = Preflight.run("my specific prompt", @test_path)
      assert result.prompt == "my specific prompt"
    end

    test "timestamp is ISO 8601" do
      {:ok, result} = Preflight.run("test", @test_path)
      assert {:ok, _, _} = DateTime.from_iso8601(result.timestamp)
    end

    test "modules is a list" do
      {:ok, result} = Preflight.run("test", @test_path)
      assert is_list(result.modules)
    end

    test "suggested_tools is a list" do
      {:ok, result} = Preflight.run("test", @test_path)
      assert is_list(result.suggested_tools)
    end
  end

  describe "run/3 summary structure" do
    test "summary has expected keys" do
      {:ok, result} = Preflight.run("analyze modules", @test_path)
      summary = result.summary

      assert Map.has_key?(summary, :total_modules)
      assert Map.has_key?(summary, :high_risk_count)
      assert Map.has_key?(summary, :hub_count)
      assert Map.has_key?(summary, :integrity_status)
      assert Map.has_key?(summary, :semantic_drift_count)
    end

    test "summary counts are non-negative integers" do
      {:ok, result} = Preflight.run("test query", @test_path)
      summary = result.summary

      assert summary.total_modules >= 0
      assert summary.high_risk_count >= 0
      assert summary.hub_count >= 0
      assert summary.semantic_drift_count >= 0
    end
  end

  describe "run/3 with options" do
    test "respects top_k option" do
      {:ok, result} = Preflight.run("test", @test_path, top_k: 2)
      assert length(result.modules) <= 2
    end
  end

  describe "run/3 module contracts" do
    test "each module has 7 contract sections when modules found" do
      {:ok, result} = Preflight.run("registry tools", @test_path, top_k: 1)

      for mod <- result.modules do
        assert Map.has_key?(mod, :module)
        assert Map.has_key?(mod, :file)
        assert Map.has_key?(mod, :relevance_score)
        assert Map.has_key?(mod, :behaviour_contract)
        assert Map.has_key?(mod, :type_contract)
        assert Map.has_key?(mod, :data_contract)
        assert Map.has_key?(mod, :macro_contract)
        assert Map.has_key?(mod, :topology)
        assert Map.has_key?(mod, :semantic_integrity)
        assert Map.has_key?(mod, :runtime_alert)
      end
    end
  end

  describe "run/3 error resilience" do
    test "handles nonexistent project path gracefully" do
      result = Preflight.run("test", "/nonexistent/path")
      # Should succeed with empty modules or error gracefully
      case result do
        {:ok, r} ->
          assert is_list(r.modules)

        {:error, _} ->
          :ok
      end
    end
  end
end
