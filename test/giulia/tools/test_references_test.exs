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

  describe "referenced_functions/1" do
    test "returns empty MapSet when test/ directory does not exist" do
      refs = TestReferences.referenced_functions("/nonexistent/path/123")
      assert MapSet.size(refs) == 0
    end

    test "collects fully-qualified function calls with arity" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            test "calls" do
              MyApp.Foo.bar(:a)
              MyApp.Foo.baz(:a, :b)
              MyApp.Other.no_args()
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "MyApp.Foo.bar/1" in refs
          assert "MyApp.Foo.baz/2" in refs
          assert "MyApp.Other.no_args/0" in refs
        end
      )
    end

    test "collects function captures `&Mod.fn/N`" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            test "captures" do
              fun = &MyApp.Foo.bar/2
              fun.(1, 2)
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "MyApp.Foo.bar/2" in refs
        end
      )
    end

    test "collects MFA tuple literals with literal arg list" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            test "mfa tuple" do
              spec = {MyApp.Worker, :start_link, [:opt1, :opt2]}
              _ = spec
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "MyApp.Worker.start_link/2" in refs
        end
      )
    end

    test "skips MFA tuple with non-literal arg list" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            test "mfa with var args" do
              args = [:foo]
              spec = {MyApp.Worker, :start_link, args}
              _ = spec
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          # Arity unknown → not added (no false positive at any synthetic arity).
          refute Enum.any?(refs, &String.starts_with?(&1, "MyApp.Worker.start_link/"))
        end
      )
    end

    test "resolves head alias before recording the MFA (item 2h)" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            alias AlexClawTest.Skills.EchoSkill

            test "calls aliased module" do
              EchoSkill.config_help()
              EchoSkill.prompt_help(:foo, :bar)
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "AlexClawTest.Skills.EchoSkill.config_help/0" in refs
          assert "AlexClawTest.Skills.EchoSkill.prompt_help/2" in refs
          # The short form must NOT appear — that was the bug 2h fixed.
          refute "EchoSkill.config_help/0" in refs
        end
      )
    end

    test "resolves multi-alias `alias Mod.{A, B}` head aliases" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            alias Plausible.TestUtils.{Auth, Sites}

            test "calls" do
              Auth.create_user()
              Sites.add_site(:opts)
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "Plausible.TestUtils.Auth.create_user/0" in refs
          assert "Plausible.TestUtils.Sites.add_site/1" in refs
        end
      )
    end

    test "respects `alias Mod, as: Other` rename" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            alias AlexClawTest.Skills.EchoSkill, as: Skill

            test "calls renamed alias" do
              Skill.config_help()
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "AlexClawTest.Skills.EchoSkill.config_help/0" in refs
        end
      )
    end

    test "leaves already-fully-qualified calls unchanged" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            alias AlexClawTest.Skills.EchoSkill

            test "fully-qualified call shouldn't be re-expanded" do
              Plausible.TestUtils.tmp_dir()
            end
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert "Plausible.TestUtils.tmp_dir/0" in refs
        end
      )
    end

    test "ignores bare alias / use / require nodes (those are module-only signals)" do
      with_project(
        %{
          "demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            alias MyApp.Foo
            require MyApp.Bar
          end
          """
        },
        fn dir ->
          refs = TestReferences.referenced_functions(dir)
          assert MapSet.size(refs) == 0
        end
      )
    end
  end
end
