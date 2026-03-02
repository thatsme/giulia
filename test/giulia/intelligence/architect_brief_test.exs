defmodule Giulia.Intelligence.ArchitectBriefTest do
  @moduledoc """
  Tests for Intelligence.ArchitectBrief — single-call project briefing.

  Pure functional module. Always returns {:ok, brief} on success.
  Each section is independently error-handled with fallbacks.
  """
  use ExUnit.Case, async: false

  alias Giulia.Intelligence.ArchitectBrief

  @test_path "D:/Development/GitHub/Giulia"

  describe "build/1 basic contract" do
    test "returns {:ok, map()} for a valid project path" do
      assert {:ok, brief} = ArchitectBrief.build(@test_path)
      assert is_map(brief)
    end

    test "includes all required sections" do
      {:ok, brief} = ArchitectBrief.build(@test_path)

      assert Map.has_key?(brief, :brief_version)
      assert Map.has_key?(brief, :timestamp)
      assert Map.has_key?(brief, :project)
      assert Map.has_key?(brief, :topology)
      assert Map.has_key?(brief, :health)
      assert Map.has_key?(brief, :runtime)
      assert Map.has_key?(brief, :constitution)
    end

    test "brief_version is a string" do
      {:ok, brief} = ArchitectBrief.build(@test_path)
      assert is_binary(brief.brief_version)
    end

    test "timestamp is ISO 8601" do
      {:ok, brief} = ArchitectBrief.build(@test_path)
      assert is_binary(brief.timestamp)
      assert {:ok, _, _} = DateTime.from_iso8601(brief.timestamp)
    end
  end

  describe "build/1 project section" do
    test "project section has expected shape" do
      {:ok, brief} = ArchitectBrief.build(@test_path)
      project = brief.project

      assert is_map(project)
      # Should contain module/function counts from the index
      assert Map.has_key?(project, :module_count) or Map.has_key?(project, :modules)
    end
  end

  describe "build/1 with invalid path" do
    test "handles nonexistent project gracefully" do
      result = ArchitectBrief.build("/nonexistent/path/nowhere")
      # Should return {:ok, _} with fallback sections or {:error, _}
      case result do
        {:ok, brief} ->
          assert is_map(brief)

        {:error, reason} ->
          assert is_tuple(reason)
      end
    end
  end

  describe "build/1 topology section" do
    test "topology section is a map" do
      {:ok, brief} = ArchitectBrief.build(@test_path)
      assert is_map(brief.topology)
    end
  end

  describe "build/1 health section" do
    test "health section is a map" do
      {:ok, brief} = ArchitectBrief.build(@test_path)
      assert is_map(brief.health)
    end
  end
end
