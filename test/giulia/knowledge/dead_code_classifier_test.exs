defmodule Giulia.Knowledge.DeadCodeClassifierTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.DeadCodeClassifier

  defp signals(opts \\ []) do
    %{
      test_function_refs: Keyword.get(opts, :test_refs, MapSet.new()),
      application_mod?: Keyword.get(opts, :app, true),
      has_templates?: Keyword.get(opts, :templates, false)
    }
  end

  defp entry(opts \\ []) do
    %{
      module: Keyword.get(opts, :module, "MyApp.Foo"),
      name: Keyword.get(opts, :name, "bar"),
      arity: Keyword.get(opts, :arity, 1),
      type: Keyword.get(opts, :type, :def),
      file: "lib/foo.ex",
      line: 10
    }
  end

  describe "classify/2 — categories" do
    test ":test_only when function is referenced from a test file" do
      s = signals(test_refs: MapSet.new(["MyApp.Foo.bar/1"]))
      assert DeadCodeClassifier.classify(entry(), s) == :test_only
    end

    test ":library_public_api when type is :def and project is library-shaped" do
      s = signals(app: false)
      assert DeadCodeClassifier.classify(entry(type: :def), s) == :library_public_api
    end

    test ":library_public_api does NOT fire on :defp even in a library" do
      s = signals(app: false)
      assert DeadCodeClassifier.classify(entry(type: :defp), s) == :genuine
    end

    test ":library_public_api does NOT fire when project is an application" do
      s = signals(app: true)
      assert DeadCodeClassifier.classify(entry(type: :def), s) == :genuine
    end

    test ":template_pending when project contains template files" do
      s = signals(app: true, templates: true)
      assert DeadCodeClassifier.classify(entry(type: :defp), s) == :template_pending
    end

    test ":genuine when no signal matches" do
      assert DeadCodeClassifier.classify(entry(type: :defp), signals()) == :genuine
    end
  end

  describe "classify/2 — precedence" do
    test ":test_only wins over :library_public_api" do
      s =
        signals(
          test_refs: MapSet.new(["MyApp.Foo.bar/1"]),
          app: false
        )

      assert DeadCodeClassifier.classify(entry(type: :def), s) == :test_only
    end

    test ":test_only wins over :template_pending" do
      s =
        signals(
          test_refs: MapSet.new(["MyApp.Foo.bar/1"]),
          templates: true
        )

      assert DeadCodeClassifier.classify(entry(), s) == :test_only
    end

    test ":library_public_api wins over :template_pending" do
      s = signals(app: false, templates: true)
      assert DeadCodeClassifier.classify(entry(type: :def), s) == :library_public_api
    end
  end

  describe "classify/2 — boundary conditions" do
    test "arity 0 function is classifiable" do
      s = signals(test_refs: MapSet.new(["MyApp.Foo.bar/0"]))
      assert DeadCodeClassifier.classify(entry(arity: 0), s) == :test_only
    end

    test "near-miss in test_function_refs (different arity) does not match" do
      s = signals(test_refs: MapSet.new(["MyApp.Foo.bar/2"]))
      assert DeadCodeClassifier.classify(entry(arity: 1), s) == :genuine
    end

    test "near-miss in test_function_refs (different module) does not match" do
      s = signals(test_refs: MapSet.new(["MyApp.Other.bar/1"]))
      assert DeadCodeClassifier.classify(entry(), s) == :genuine
    end
  end

  describe "summarize/1" do
    test "empty list yields zero counts and zero buckets" do
      summary = DeadCodeClassifier.summarize([])

      assert summary.irreducible == 0
      assert summary.actionable == 0
      assert summary.by_category.genuine == 0
      assert summary.by_category.test_only == 0
      assert summary.by_category.library_public_api == 0
      assert summary.by_category.template_pending == 0
      assert summary.by_category.uncategorized == 0
    end

    test "tallies by category and computes irreducible/actionable buckets" do
      classified = [
        %{category: :genuine},
        %{category: :genuine},
        %{category: :test_only},
        %{category: :library_public_api},
        %{category: :library_public_api},
        %{category: :template_pending},
        %{category: :uncategorized}
      ]

      summary = DeadCodeClassifier.summarize(classified)

      assert summary.by_category.genuine == 2
      assert summary.by_category.test_only == 1
      assert summary.by_category.library_public_api == 2
      assert summary.by_category.template_pending == 1
      assert summary.by_category.uncategorized == 1

      # irreducible = test_only + library_public_api + template_pending = 1 + 2 + 1 = 4
      assert summary.irreducible == 4
      # actionable = genuine + uncategorized = 2 + 1 = 3
      assert summary.actionable == 3
    end
  end

  defp with_project(files, callback) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dc_classifier_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      for {rel, content} <- files do
        path = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      callback.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  describe "compute_signals/2 — integration with project filesystem" do
    test "returns empty / false signals on a barebones project" do
      with_project(%{"README.md" => "hi"}, fn dir ->
        s = DeadCodeClassifier.compute_signals(dir, %{})

        assert MapSet.size(s.test_function_refs) == 0
        assert s.application_mod? == false
        assert s.has_templates? == false
      end)
    end

    test "detects application_mod? from mix.exs application/0" do
      with_project(
        %{
          "mix.exs" => """
          defmodule MyApp.MixProject do
            use Mix.Project

            def project, do: [app: :my_app, version: "0.1.0"]

            def application do
              [mod: {MyApp.Application, []}, extra_applications: [:logger]]
            end
          end
          """
        },
        fn dir ->
          s = DeadCodeClassifier.compute_signals(dir, %{})
          assert s.application_mod? == true
        end
      )
    end

    test "library-shaped mix.exs (no :mod entry) yields application_mod? == false" do
      with_project(
        %{
          "mix.exs" => """
          defmodule MyLib.MixProject do
            use Mix.Project

            def project, do: [app: :my_lib, version: "0.1.0"]

            def application do
              [extra_applications: [:logger]]
            end
          end
          """
        },
        fn dir ->
          s = DeadCodeClassifier.compute_signals(dir, %{})
          assert s.application_mod? == false
        end
      )
    end

    test "detects has_templates? when *.heex file is present anywhere" do
      with_project(
        %{
          "lib/my_app_web/templates/page/index.html.heex" => "<h1>hi</h1>"
        },
        fn dir ->
          s = DeadCodeClassifier.compute_signals(dir, %{})
          assert s.has_templates? == true
        end
      )
    end

    test "detects has_templates? for *.eex too" do
      with_project(
        %{"lib/my_app/template.eex" => "<%= @x %>"},
        fn dir ->
          s = DeadCodeClassifier.compute_signals(dir, %{})
          assert s.has_templates? == true
        end
      )
    end

    test "collects test_function_refs from *_test.exs files" do
      with_project(
        %{
          "test/my_app_test.exs" => """
          defmodule MyAppTest do
            use ExUnit.Case
            test "calls the lib function" do
              MyApp.Foo.bar(:something)
            end
          end
          """
        },
        fn dir ->
          s = DeadCodeClassifier.compute_signals(dir, %{})
          assert "MyApp.Foo.bar/1" in s.test_function_refs
        end
      )
    end
  end
end
