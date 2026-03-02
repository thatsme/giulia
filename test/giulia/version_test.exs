defmodule Giulia.VersionTest do
  @moduledoc """
  Tests for Giulia.Version — compile-time version and build tracking.
  """
  use ExUnit.Case, async: true

  alias Giulia.Version

  describe "version/0" do
    test "returns a semantic version string" do
      version = Version.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+$/
    end
  end

  describe "build/0" do
    test "returns a positive integer" do
      build = Version.build()
      assert is_integer(build)
      assert build > 0
    end
  end

  describe "short_version/0" do
    test "combines version and build" do
      short = Version.short_version()
      assert is_binary(short)
      assert short =~ ~r/^v\d+\.\d+\.\d+\.\d+$/
    end

    test "includes the actual version and build" do
      short = Version.short_version()
      assert short == "v#{Version.version()}.#{Version.build()}"
    end
  end
end
