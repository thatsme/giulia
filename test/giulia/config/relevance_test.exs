defmodule Giulia.Config.RelevanceTest do
  use ExUnit.Case, async: true

  alias Giulia.Config.Relevance

  test "current/0 loads the JSON config and exposes the three top-level keys" do
    cfg = Relevance.current()
    assert is_map(cfg)
    assert is_map(cfg.dead_code)
    assert is_map(cfg.conventions)
    assert is_map(cfg.duplicates)
  end

  test "current/0 is stable — repeated calls return identical persistent_term" do
    a = Relevance.current()
    b = Relevance.current()
    assert a == b
  end

  describe "dead_code_categories/1" do
    test "high returns a MapSet containing :genuine" do
      set = Relevance.dead_code_categories("high")
      assert is_struct(set, MapSet)
      assert MapSet.member?(set, :genuine)
      refute MapSet.member?(set, :test_only)
      refute MapSet.member?(set, :library_public_api)
    end

    test "medium returns a MapSet covering :genuine + :uncategorized (the actionable rollup)" do
      set = Relevance.dead_code_categories("medium")
      assert MapSet.member?(set, :genuine)
      assert MapSet.member?(set, :uncategorized)
      refute MapSet.member?(set, :test_only)
      refute MapSet.member?(set, :library_public_api)
    end

    test "all returns the :all sentinel (no filter)" do
      assert Relevance.dead_code_categories("all") == :all
    end

    test "nil returns :all (silent default per design)" do
      assert Relevance.dead_code_categories(nil) == :all
    end

    test "unrecognised value returns :all (silent default per design)" do
      assert Relevance.dead_code_categories("foo") == :all
      assert Relevance.dead_code_categories("") == :all
    end
  end

  describe "convention_severities/1" do
    test "high returns a MapSet containing only \"error\"" do
      set = Relevance.convention_severities("high")
      assert is_struct(set, MapSet)
      assert MapSet.member?(set, "error")
      refute MapSet.member?(set, "warning")
      refute MapSet.member?(set, "info")
    end

    test "medium returns a MapSet covering \"error\" + \"warning\"" do
      set = Relevance.convention_severities("medium")
      assert MapSet.member?(set, "error")
      assert MapSet.member?(set, "warning")
      refute MapSet.member?(set, "info")
    end

    test "all returns the :all sentinel" do
      assert Relevance.convention_severities("all") == :all
    end

    test "nil and unrecognised values return :all" do
      assert Relevance.convention_severities(nil) == :all
      assert Relevance.convention_severities("foo") == :all
    end
  end

  describe "duplicate_threshold/2" do
    test "high tightens to 0.95 when supplied threshold is below" do
      assert Relevance.duplicate_threshold("high", 0.85) == 0.95
      assert Relevance.duplicate_threshold("high", 0.50) == 0.95
    end

    test "high keeps supplied threshold when supplied is above bucket" do
      assert Relevance.duplicate_threshold("high", 0.99) == 0.99
    end

    test "medium tightens to 0.90 when supplied threshold is below" do
      assert Relevance.duplicate_threshold("medium", 0.85) == 0.90
    end

    test "medium keeps supplied threshold when supplied is above bucket" do
      assert Relevance.duplicate_threshold("medium", 0.95) == 0.95
    end

    test "all returns the supplied threshold unchanged" do
      assert Relevance.duplicate_threshold("all", 0.85) == 0.85
      assert Relevance.duplicate_threshold("all", 0.99) == 0.99
    end

    test "nil returns the supplied threshold unchanged" do
      assert Relevance.duplicate_threshold(nil, 0.85) == 0.85
    end

    test "unrecognised value returns the supplied threshold unchanged" do
      assert Relevance.duplicate_threshold("foo", 0.85) == 0.85
    end
  end

  test "reload/0 returns a structurally equivalent map" do
    original = Relevance.current()
    reloaded = Relevance.reload()
    assert Map.keys(original) == Map.keys(reloaded)
    assert original == reloaded
  end
end
