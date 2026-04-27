defmodule Giulia.Enrichment.RegistryTest do
  use ExUnit.Case, async: false

  alias Giulia.Enrichment.Registry

  setup do
    # Reload so the registry reflects the on-disk config exactly.
    # Other tests in the suite may have populated :persistent_term.
    Registry.reload()
    :ok
  end

  describe "sources/0" do
    test "returns the credo source mapping" do
      sources = Registry.sources()
      assert Map.fetch(sources, :credo) == {:ok, Giulia.Enrichment.Sources.Credo}
    end
  end

  describe "fetch_source/1" do
    test "accepts atom and string forms" do
      assert {:ok, Giulia.Enrichment.Sources.Credo} = Registry.fetch_source(:credo)
      assert {:ok, Giulia.Enrichment.Sources.Credo} = Registry.fetch_source("credo")
    end

    test "returns :error for unregistered tools" do
      assert :error = Registry.fetch_source(:nonexistent_tool_zzz)
      assert :error = Registry.fetch_source("nonexistent_tool_zzz")
    end
  end

  describe "config_for/1" do
    test "returns the per-source config map" do
      cfg = Registry.config_for(:credo)
      assert is_map(cfg)
      assert Map.has_key?(cfg, "severity_map")
      assert Map.has_key?(cfg, "default_severity")
    end

    test "returns %{} for unregistered tools" do
      assert Registry.config_for(:nonexistent_tool_zzz) == %{}
      assert Registry.config_for("nonexistent_tool_zzz") == %{}
    end
  end

  describe "severity_for/2 — Credo mapping (driven by JSON config)" do
    test "Credo's misleadingly-named 'warning' category maps to :error" do
      assert Registry.severity_for(:credo, "warning") == :error
    end

    test "'design' and 'refactor' map to :warning" do
      assert Registry.severity_for(:credo, "design") == :warning
      assert Registry.severity_for(:credo, "refactor") == :warning
    end

    test "'readability' and 'consistency' map to :info" do
      assert Registry.severity_for(:credo, "readability") == :info
      assert Registry.severity_for(:credo, "consistency") == :info
    end

    test "unknown category falls back to default_severity" do
      assert Registry.severity_for(:credo, "frobnication") == :info
    end

    test "nil category falls back to default_severity" do
      assert Registry.severity_for(:credo, nil) == :info
    end

    test "unregistered tool falls back to :info" do
      assert Registry.severity_for(:nonexistent_tool_zzz, "anything") == :info
    end
  end
end
