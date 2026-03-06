defmodule Giulia.Context.BuilderTest do
  use ExUnit.Case, async: true

  alias Giulia.Context.Builder

  describe "build_correction_message/3" do
    test "formats map errors" do
      msg = Builder.build_correction_message("edit_file", %{path: ["is required"]})
      assert msg =~ "VALIDATION ERROR"
      assert msg =~ "edit_file"
      assert msg =~ "path"
      assert msg =~ "is required"
    end

    test "includes valid_options when provided" do
      msg = Builder.build_correction_message("think", %{thought: ["can't be blank"]}, ["thought"])
      assert msg =~ "Valid options"
      assert msg =~ "thought"
    end

    test "handles non-map errors" do
      msg = Builder.build_correction_message("foo", :bad_input)
      assert msg =~ "VALIDATION ERROR"
      assert msg =~ ":bad_input"
    end
  end

  describe "build_observation/2" do
    test "formats success result" do
      obs = Builder.build_observation("read_file", {:ok, "file contents here"})
      assert obs =~ "OBSERVATION [read_file]"
      assert obs =~ "Success"
      assert obs =~ "file contents here"
    end

    test "formats error result" do
      obs = Builder.build_observation("write_file", {:error, :permission_denied})
      assert obs =~ "OBSERVATION [write_file]"
      assert obs =~ "Failed"
      assert obs =~ "permission_denied"
    end

    test "truncates long success output" do
      long_output = String.duplicate("x", 3000)
      obs = Builder.build_observation("read_file", {:ok, long_output})
      assert obs =~ "truncated"
      assert String.length(obs) < 3000
    end
  end

  describe "build_system_prompt/1" do
    test "includes all sections" do
      prompt = Builder.build_system_prompt(project_path: "/tmp/nonexistent")
      assert prompt =~ "CONSTITUTION"
      assert prompt =~ "AVAILABLE TOOLS"
      assert prompt =~ "ENVIRONMENT"
      assert prompt =~ "CONSTRAINTS"
    end
  end

  describe "build_minimal_prompt/1" do
    test "includes constitution and constraints but not environment" do
      prompt = Builder.build_minimal_prompt()
      assert prompt =~ "CONSTITUTION"
      assert prompt =~ "CONSTRAINTS"
      assert prompt =~ "AVAILABLE TOOLS"
    end
  end

  describe "build_intervention_message/3" do
    test "includes attempt count and errors" do
      msg = Builder.build_intervention_message(3, ["syntax error", "file not found"])
      assert msg =~ "INTERVENTION"
      assert msg =~ "3 consecutive"
      assert msg =~ "syntax error"
      assert msg =~ "file not found"
      assert msg =~ "different approach"
    end
  end
end
