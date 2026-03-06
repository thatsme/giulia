defmodule Giulia.Knowledge.InsightsTest do
  use ExUnit.Case, async: false

  alias Giulia.Knowledge.Insights
  alias Giulia.Context.Store

  @test_path "/tmp/insights_test_#{:rand.uniform(10000)}"

  setup do
    # Seed ETS with test AST data
    ast_with_orphan = %{
      modules: [%{name: "MyApp.Accounts", line: 1, moduledoc: nil}],
      functions: [
        %{name: :get_user, arity: 1, type: :def, line: 5},
        %{name: :list_users, arity: 0, type: :def, line: 10}
      ],
      imports: [],
      types: [],
      specs: [
        %{function: :get_user, arity: 1, spec: "get_user(integer()) :: map()", line: 4},
        # Orphan spec — no matching function
        %{function: :delete_user, arity: 1, spec: "delete_user(integer()) :: :ok", line: 20}
      ],
      callbacks: [],
      optional_callbacks: [],
      structs: [%{module: "MyApp.Accounts", fields: [:name, :email], line: 2}],
      docs: [],
      line_count: 25,
      complexity: 3
    }

    ast_clean = %{
      modules: [%{name: "MyApp.Repo", line: 1, moduledoc: nil}],
      functions: [
        %{name: :all, arity: 1, type: :def, line: 3},
        %{name: :get, arity: 2, type: :def, line: 8},
        %{name: :internal, arity: 0, type: :defp, line: 12}
      ],
      imports: [],
      types: [],
      specs: [
        %{function: :all, arity: 1, spec: "all(module()) :: [map()]", line: 2},
        %{function: :get, arity: 2, spec: "get(module(), integer()) :: map() | nil", line: 7}
      ],
      callbacks: [],
      optional_callbacks: [],
      structs: [],
      docs: [],
      line_count: 15,
      complexity: 2
    }

    Store.put_ast(@test_path, "lib/my_app/accounts.ex", ast_with_orphan)
    Store.put_ast(@test_path, "lib/my_app/repo.ex", ast_clean)

    on_exit(fn -> Store.clear_asts(@test_path) end)

    %{path: @test_path}
  end

  describe "orphan_specs/1" do
    test "finds specs without matching functions", %{path: path} do
      {:ok, %{orphans: orphans, count: count}} = Insights.orphan_specs(path)
      assert count == 1
      orphan = hd(orphans)
      assert orphan.module == "MyApp.Accounts"
      assert orphan.spec_function == "delete_user"
      assert orphan.spec_arity == 1
    end

    test "returns empty for project with no orphans" do
      clean_path = "/tmp/insights_clean_#{:rand.uniform(10000)}"

      Store.put_ast(clean_path, "lib/clean.ex", %{
        modules: [%{name: "Clean", line: 1, moduledoc: nil}],
        functions: [%{name: :run, arity: 0, type: :def, line: 2}],
        specs: [%{function: :run, arity: 0, spec: "run() :: :ok", line: 1}],
        imports: [], types: [], callbacks: [], optional_callbacks: [],
        structs: [], docs: [], line_count: 5, complexity: 1
      })

      {:ok, %{orphans: [], count: 0}} = Insights.orphan_specs(clean_path)
      Store.clear_asts(clean_path)
    end
  end

  describe "api_surface/1" do
    test "computes public/private ratio per module", %{path: path} do
      {:ok, %{modules: modules, count: count}} = Insights.api_surface(path)
      assert count == 2

      accounts = Enum.find(modules, fn m -> m.module == "MyApp.Accounts" end)
      assert accounts.public == 2
      assert accounts.private == 0
      assert accounts.ratio == 1.0

      repo = Enum.find(modules, fn m -> m.module == "MyApp.Repo" end)
      assert repo.public == 2
      assert repo.private == 1
      assert repo.ratio == 0.67
    end
  end

  describe "logic_flow/4" do
    test "returns path between two MFA vertices" do
      graph =
        Graph.new()
        |> Graph.add_vertex("A.foo/1", :mfa)
        |> Graph.add_vertex("B.bar/2", :mfa)
        |> Graph.add_vertex("C.baz/0", :mfa)
        |> Graph.add_edge("A.foo/1", "B.bar/2")
        |> Graph.add_edge("B.bar/2", "C.baz/0")

      {:ok, steps} = Insights.logic_flow(graph, @test_path, "A.foo/1", "C.baz/0")
      assert length(steps) == 3
      assert hd(steps).mfa == "A.foo/1"
      assert List.last(steps).mfa == "C.baz/0"
    end

    test "returns :no_path when vertices are disconnected" do
      graph =
        Graph.new()
        |> Graph.add_vertex("A.foo/1", :mfa)
        |> Graph.add_vertex("B.bar/2", :mfa)

      {:ok, :no_path} = Insights.logic_flow(graph, @test_path, "A.foo/1", "B.bar/2")
    end

    test "returns error for missing from vertex" do
      graph = Graph.new() |> Graph.add_vertex("B.bar/2", :mfa)
      {:error, {:not_found, "A.foo/1"}} = Insights.logic_flow(graph, @test_path, "A.foo/1", "B.bar/2")
    end

    test "returns error for missing to vertex" do
      graph = Graph.new() |> Graph.add_vertex("A.foo/1", :mfa)
      {:error, {:not_found, "B.bar/2"}} = Insights.logic_flow(graph, @test_path, "A.foo/1", "B.bar/2")
    end
  end

  describe "pre_impact_check/3" do
    test "returns error for unknown action" do
      graph = Graph.new()
      {:error, {:unknown_action, "nope"}} =
        Insights.pre_impact_check(graph, @test_path, %{"action" => "nope"})
    end

    test "returns error for invalid target format" do
      graph = Graph.new()
      {:error, {:invalid_target, "bad"}} =
        Insights.pre_impact_check(graph, @test_path, %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bad",
          "new_name" => "new_func"
        })
    end

    test "returns error when MFA not in graph" do
      graph = Graph.new()
      {:error, {:not_found, "Foo.bar/2"}} =
        Insights.pre_impact_check(graph, @test_path, %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bar/2",
          "new_name" => "baz"
        })
    end

    test "rename_function returns impact analysis" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/2", :mfa)
        |> Graph.add_vertex("Foo", :module)

      {:ok, result} =
        Insights.pre_impact_check(graph, @test_path, %{
          "action" => "rename_function",
          "module" => "Foo",
          "target" => "bar/2",
          "new_name" => "baz"
        })

      assert result.action == "rename_function"
      assert result.target == "Foo.bar/2"
      assert result.new_name == "Foo.baz/2"
      assert is_list(result.phases)
    end

    test "remove_function returns impact analysis" do
      graph =
        Graph.new()
        |> Graph.add_vertex("Foo.bar/1", :mfa)
        |> Graph.add_vertex("Foo", :module)

      {:ok, result} =
        Insights.pre_impact_check(graph, @test_path, %{
          "action" => "remove_function",
          "module" => "Foo",
          "target" => "bar/1"
        })

      assert result.action == "remove_function"
      assert result.target == "Foo.bar/1"
      assert is_list(result.potentially_orphaned)
    end

    test "rename_module returns error when module not in graph" do
      graph = Graph.new()
      {:error, {:not_found, "Old"}} =
        Insights.pre_impact_check(graph, @test_path, %{
          "action" => "rename_module",
          "module" => "Old",
          "new_name" => "New"
        })
    end
  end
end
