defmodule Giulia.Inference.ContextBuilder.PreviewTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.ContextBuilder.Preview
  alias Giulia.Inference.State

  @state State.new(project_path: "/tmp/preview_test")

  describe "generate_preview/3 — run_tests" do
    test "shows file and test_name" do
      result = Preview.generate_preview("run_tests", %{"file" => "test/foo_test.exs", "test_name" => "works"}, @state)
      assert result =~ "test/foo_test.exs"
      assert result =~ "works"
    end

    test "shows file only" do
      result = Preview.generate_preview("run_tests", %{"file" => "test/foo_test.exs"}, @state)
      assert result =~ "test/foo_test.exs"
    end

    test "shows test_name only" do
      result = Preview.generate_preview("run_tests", %{"test_name" => "my test"}, @state)
      assert result =~ "my test"
    end

    test "shows ALL when no params" do
      result = Preview.generate_preview("run_tests", %{}, @state)
      assert result =~ "ALL"
    end
  end

  describe "generate_preview/3 — unknown tool" do
    test "falls back to inspect" do
      result = Preview.generate_preview("unknown_tool", %{"key" => "val"}, @state)
      assert result =~ "unknown_tool"
      assert result =~ "key"
    end
  end
end
