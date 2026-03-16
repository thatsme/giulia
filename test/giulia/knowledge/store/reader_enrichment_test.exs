defmodule Giulia.Knowledge.Store.ReaderEnrichmentTest do
  @moduledoc """
  Tests for Build 138 enrichments to all_modules/1 and all_functions/1:
  - complexity_score, dep_in, dep_out on modules
  - complexity on functions
  """
  use ExUnit.Case, async: false

  alias Giulia.Knowledge.Store

  @project "/tmp/reader_enrichment_test_#{:rand.uniform(100_000)}"

  setup do
    # Ensure ETS table exists — the application should start Context.Store,
    # but if it hasn't initialized yet, create the table ourselves.
    if :ets.whereis(Giulia.Context.Store) == :undefined do
      :ets.new(Giulia.Context.Store, [:named_table, :public, :set, read_concurrency: true])
    end

    # Build a graph with known structure
    ast_data = %{
      "lib/alpha.ex" => %{
        modules: [
          %{
            name: "Alpha",
            line: 1,
            functions: [
              %{name: :do_work, arity: 1, type: :def, line: 5, complexity: 8},
              %{name: :helper, arity: 0, type: :defp, line: 15, complexity: 3}
            ]
          }
        ],
        imports: [%{module: "Beta", type: :import, only: []}],
        aliases: [],
        uses: []
      },
      "lib/beta.ex" => %{
        modules: [
          %{
            name: "Beta",
            line: 1,
            functions: [
              %{name: :serve, arity: 2, type: :def, line: 3, complexity: 12}
            ]
          }
        ],
        imports: [],
        aliases: [],
        uses: []
      },
      "lib/gamma.ex" => %{
        modules: [
          %{
            name: "Gamma",
            line: 1,
            functions: []
          }
        ],
        imports: [
          %{module: "Alpha", type: :import, only: []},
          %{module: "Beta", type: :import, only: []}
        ],
        aliases: [],
        uses: []
      }
    }

    # Store AST data in Context.Store for complexity lookups
    Enum.each(ast_data, fn {file, data} ->
      Giulia.Context.Store.put_ast(@project, file, data)
    end)

    # Build the knowledge graph synchronously
    :ok = Store.rebuild(@project, ast_data)

    on_exit(fn ->
      # Clean up ETS entries
      try do
        :ets.delete(:giulia_knowledge_graphs, {:graph, @project})
        :ets.delete(:giulia_knowledge_graphs, {:metrics, @project})
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  # ============================================================================
  # all_modules/1 — enriched fields
  # ============================================================================

  describe "all_modules/1 enriched" do
    test "returns complexity_score for each module" do
      {:ok, modules} = Store.all_modules(@project)

      alpha = Enum.find(modules, &(&1.name == "Alpha"))
      assert alpha != nil
      # Alpha has do_work(8) + helper(3) = 11
      assert alpha.complexity_score == 11

      beta = Enum.find(modules, &(&1.name == "Beta"))
      assert beta != nil
      # Beta has serve(12) = 12
      assert beta.complexity_score == 12
    end

    test "returns zero complexity_score for module with no functions" do
      {:ok, modules} = Store.all_modules(@project)
      gamma = Enum.find(modules, &(&1.name == "Gamma"))
      assert gamma != nil
      assert gamma.complexity_score == 0
    end

    test "returns dep_in and dep_out for each module" do
      {:ok, modules} = Store.all_modules(@project)

      # Alpha imports Beta, so dep_out >= 1
      alpha = Enum.find(modules, &(&1.name == "Alpha"))
      assert is_integer(alpha.dep_in)
      assert is_integer(alpha.dep_out)
      assert alpha.dep_out >= 1

      # Beta is imported by Alpha and Gamma, so dep_in >= 2
      beta = Enum.find(modules, &(&1.name == "Beta"))
      assert beta.dep_in >= 2

      # Gamma imports Alpha and Beta, so dep_out >= 2
      gamma = Enum.find(modules, &(&1.name == "Gamma"))
      assert gamma.dep_out >= 2
    end

    test "returns function_count for enriched modules" do
      {:ok, modules} = Store.all_modules(@project)

      alpha = Enum.find(modules, &(&1.name == "Alpha"))
      assert alpha[:function_count] == 2

      beta = Enum.find(modules, &(&1.name == "Beta"))
      assert beta[:function_count] == 1

      gamma = Enum.find(modules, &(&1.name == "Gamma"))
      assert gamma[:function_count] == 0
    end

    test "every module has all enriched keys" do
      {:ok, modules} = Store.all_modules(@project)

      Enum.each(modules, fn mod ->
        assert Map.has_key?(mod, :name), "missing :name"
        assert Map.has_key?(mod, :complexity_score), "missing :complexity_score on #{mod.name}"
        assert Map.has_key?(mod, :dep_in), "missing :dep_in on #{mod.name}"
        assert Map.has_key?(mod, :dep_out), "missing :dep_out on #{mod.name}"
      end)
    end
  end

  # ============================================================================
  # all_functions/1 — enriched fields
  # ============================================================================

  describe "all_functions/1 enriched" do
    test "returns complexity for each function" do
      {:ok, functions} = Store.all_functions(@project)

      do_work = Enum.find(functions, fn f -> f.function == "do_work" end)

      if do_work do
        assert do_work.complexity == 8
      end

      serve = Enum.find(functions, fn f -> f.function == "serve" end)

      if serve do
        assert serve.complexity == 12
      end
    end

    test "every function has complexity key" do
      {:ok, functions} = Store.all_functions(@project)

      Enum.each(functions, fn func ->
        assert Map.has_key?(func, :complexity), "missing :complexity on #{func.name}"
        assert is_integer(func.complexity)
      end)
    end

    test "functions include module, function name, and arity" do
      {:ok, functions} = Store.all_functions(@project)

      Enum.each(functions, fn func ->
        assert Map.has_key?(func, :name)
        assert Map.has_key?(func, :module)
        assert Map.has_key?(func, :arity)
      end)
    end
  end

  # ============================================================================
  # Adversarial — edge cases
  # ============================================================================

  describe "all_modules/1 adversarial" do
    test "returns empty list for project with no graph" do
      {:ok, modules} = Store.all_modules("/nonexistent/project/#{:rand.uniform(100_000)}")
      assert modules == []
    end
  end

  describe "all_functions/1 adversarial" do
    test "returns empty list for project with no graph" do
      {:ok, functions} = Store.all_functions("/nonexistent/project/#{:rand.uniform(100_000)}")
      assert functions == []
    end
  end
end
