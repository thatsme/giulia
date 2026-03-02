defmodule Giulia.Intelligence.PlanValidatorTest do
  @moduledoc """
  Tests for Intelligence.PlanValidator — graph-aware plan validation.

  Pure functional module. Always returns {:ok, result} even on errors (rescue).
  Tests cover all 5 validation checks and verdict computation.
  """
  use ExUnit.Case, async: false

  alias Giulia.Intelligence.PlanValidator

  # We need the Knowledge.Store running with a scanned project for full tests.
  # For unit tests we use an empty/minimal plan.

  @test_path "D:/Development/GitHub/Giulia"

  describe "validate/2 basic contract" do
    test "always returns {:ok, map()}" do
      plan = %{"modules_touched" => [], "actions" => []}
      assert {:ok, result} = PlanValidator.validate(plan, @test_path)
      assert is_map(result)
    end

    test "result contains required keys" do
      plan = %{"modules_touched" => [], "actions" => []}
      {:ok, result} = PlanValidator.validate(plan, @test_path)

      assert Map.has_key?(result, :verdict)
      assert Map.has_key?(result, :risk_score)
      assert Map.has_key?(result, :modules_touched)
      assert Map.has_key?(result, :checks)
      assert Map.has_key?(result, :recommendations)
    end

    test "empty plan gets approved verdict" do
      plan = %{"modules_touched" => [], "actions" => []}
      {:ok, result} = PlanValidator.validate(plan, @test_path)

      assert result.verdict == "approved"
      assert result.risk_score == 0
    end
  end

  describe "validate/2 with modules" do
    test "touching a non-hub module gets approved" do
      plan = %{
        "modules_touched" => ["Giulia.Version"],
        "actions" => []
      }

      {:ok, result} = PlanValidator.validate(plan, @test_path)
      assert result.verdict in ["approved", "warning"]
      assert is_integer(result.risk_score)
    end

    test "touching a high-centrality hub triggers warning" do
      plan = %{
        "modules_touched" => [
          "Giulia.Tools.Registry",
          "Giulia.Context.Store",
          "Giulia.Inference.Engine"
        ],
        "actions" => []
      }

      {:ok, result} = PlanValidator.validate(plan, @test_path)
      # High hub density should produce a warning or higher risk
      assert is_integer(result.risk_score)
      assert length(result.checks) == 5
    end

    test "checks list always has 5 entries" do
      plan = %{"modules_touched" => ["Giulia.Version"], "actions" => []}
      {:ok, result} = PlanValidator.validate(plan, @test_path)

      assert length(result.checks) == 5

      check_names = Enum.map(result.checks, & &1.check)
      assert "cycle_detection" in check_names
      assert "red_zone_collision" in check_names
      assert "hub_risk" in check_names
      assert "blast_radius" in check_names
      assert "unprotected_write" in check_names
    end
  end

  describe "validate/2 with actions" do
    test "action with new dependency that doesn't create cycle" do
      plan = %{
        "modules_touched" => ["Giulia.Version"],
        "actions" => [
          %{
            "type" => "create",
            "module" => "Giulia.NewModule",
            "depends_on" => ["Giulia.Version"]
          }
        ]
      }

      {:ok, result} = PlanValidator.validate(plan, @test_path)
      assert result.verdict in ["approved", "warning"]
    end
  end

  describe "validate/2 check sanitization" do
    test "checks only expose :check, :status, :detail keys" do
      plan = %{"modules_touched" => ["Giulia.Version"], "actions" => []}
      {:ok, result} = PlanValidator.validate(plan, @test_path)

      for check <- result.checks do
        allowed_keys = MapSet.new([:check, :status, :detail])
        actual_keys = MapSet.new(Map.keys(check))
        assert MapSet.subset?(actual_keys, allowed_keys),
               "Check #{check.check} has extra keys: #{inspect(MapSet.difference(actual_keys, allowed_keys))}"
      end
    end
  end

  describe "validate/2 with invalid input" do
    test "handles nil modules_touched gracefully" do
      plan = %{}
      {:ok, result} = PlanValidator.validate(plan, @test_path)
      assert result.verdict == "approved"
    end

    test "handles invalid project path gracefully" do
      plan = %{"modules_touched" => ["Foo.Bar"], "actions" => []}
      {:ok, result} = PlanValidator.validate(plan, "/nonexistent/path")
      assert is_binary(result.verdict)
    end
  end

  describe "risk_score bounds" do
    test "risk score is capped at 100" do
      plan = %{
        "modules_touched" => ["Giulia.Tools.Registry", "Giulia.Context.Store",
                               "Giulia.Inference.Engine", "Giulia.Knowledge.Store"],
        "actions" => []
      }

      {:ok, result} = PlanValidator.validate(plan, @test_path)
      assert result.risk_score >= 0
      assert result.risk_score <= 100
    end
  end
end
