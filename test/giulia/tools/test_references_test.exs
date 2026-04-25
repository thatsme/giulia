defmodule Giulia.Tools.TestReferencesTest do
  use ExUnit.Case, async: true

  alias Giulia.Tools.TestReferences

  defp with_project(test_files, callback) do
    dir = Path.join(System.tmp_dir!(), "test_refs_#{:erlang.unique_integer([:positive])}")
    test_dir = Path.join(dir, "test")
    File.mkdir_p!(test_dir)

    try do
      for {filename, content} <- test_files do
        path = Path.join(test_dir, filename)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      callback.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  test "returns empty MapSet when test/ directory does not exist" do
    refs = TestReferences.referenced_modules("/nonexistent/path/123")
    assert MapSet.size(refs) == 0
  end

  test "collects modules referenced via alias" do
    with_project(
      %{
        "demo_test.exs" => """
        defmodule DemoTest do
          use ExUnit.Case
          alias MyApp.Foo
          alias MyApp.Bar.Baz
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Foo" in refs
        assert "MyApp.Bar.Baz" in refs
      end
    )
  end

  test "collects modules referenced via multi-alias `alias Mod.{A, B}`" do
    with_project(
      %{
        "demo_test.exs" => """
        defmodule DemoTest do
          use ExUnit.Case
          alias MyApp.{Foo, Bar, Baz}
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Foo" in refs
        assert "MyApp.Bar" in refs
        assert "MyApp.Baz" in refs
      end
    )
  end

  test "collects modules referenced via use" do
    with_project(
      %{
        "demo_test.exs" => """
        defmodule DemoTest do
          use ExUnit.Case
          use MyApp.TestHelpers
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.TestHelpers" in refs
        assert "ExUnit.Case" in refs
      end
    )
  end

  test "collects modules referenced via @behaviour" do
    with_project(
      %{
        "stub_test.exs" => """
        defmodule StubTest do
          use ExUnit.Case
          @behaviour MyApp.Worker
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Worker" in refs
      end
    )
  end

  test "collects modules referenced via fully-qualified function calls" do
    with_project(
      %{
        "calls_test.exs" => """
        defmodule CallsTest do
          use ExUnit.Case
          test "calls" do
            assert MyApp.Calculator.add(1, 2) == 3
            assert MyApp.Other.Module.process(:input) == :ok
          end
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Calculator" in refs
        assert "MyApp.Other.Module" in refs
      end
    )
  end

  test "collects modules referenced via struct literals" do
    with_project(
      %{
        "struct_test.exs" => """
        defmodule StructTest do
          use ExUnit.Case
          test "structs" do
            user = %MyApp.User{name: "Bob"}
            assert user.name == "Bob"
          end
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.User" in refs
      end
    )
  end

  test "collects modules referenced via captures" do
    with_project(
      %{
        "capture_test.exs" => """
        defmodule CaptureTest do
          use ExUnit.Case
          test "captures" do
            Enum.map([1, 2], &MyApp.Worker.tick/1)
          end
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Worker" in refs
      end
    )
  end

  test "collects modules referenced via MFA tuple literals" do
    with_project(
      %{
        "mfa_test.exs" => """
        defmodule MFATest do
          use ExUnit.Case
          test "mfa" do
            spec = {MyApp.Producer, :run, []}
            assert is_tuple(spec)
          end
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Producer" in refs
      end
    )
  end

  test "walks nested test directories" do
    with_project(
      %{
        "subdir/nested_test.exs" => """
        defmodule NestedTest do
          use ExUnit.Case
          alias MyApp.Deep.Module
        end
        """,
        "deeply/nested/leaf_test.exs" => """
        defmodule LeafTest do
          use ExUnit.Case
          alias MyApp.Other
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Deep.Module" in refs
        assert "MyApp.Other" in refs
      end
    )
  end

  test "ignores files without _test.exs suffix" do
    with_project(
      %{
        "support/helper.ex" => """
        defmodule Helper do
          alias MyApp.Inner
        end
        """,
        "real_test.exs" => """
        defmodule RealTest do
          use ExUnit.Case
          alias MyApp.Outer
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        assert "MyApp.Outer" in refs
        refute "MyApp.Inner" in refs
      end
    )
  end

  test "handles malformed test files without crashing" do
    with_project(
      %{
        "bad_test.exs" => """
        defmodule BadTest do
          use ExUnit.Case
          this is not valid elixir(((
        """,
        "good_test.exs" => """
        defmodule GoodTest do
          use ExUnit.Case
          alias MyApp.OK
        end
        """
      },
      fn dir ->
        refs = TestReferences.referenced_modules(dir)
        # Bad file is silently skipped; good file is processed.
        assert "MyApp.OK" in refs
      end
    )
  end
end
