defmodule Giulia.Context.Store.QueryTest do
  use ExUnit.Case, async: false

  alias Giulia.Context.Store
  alias Giulia.Context.Store.Query

  @test_path "/tmp/query_test_#{:rand.uniform(10000)}"

  setup do
    # Table already exists from app supervisor — just seed data
    ast_data = %{
      modules: [%{name: "MyApp.Accounts", line: 1, moduledoc: "Account management."}],
      functions: [
        %{name: :get_user, arity: 1, type: :def, line: 5},
        %{name: :list_users, arity: 0, type: :def, line: 10},
        %{name: :validate, arity: 1, type: :defp, line: 15}
      ],
      imports: [],
      types: [%{name: :user_id, arity: 0, visibility: :type, line: 3, definition: ""}],
      specs: [%{function: :get_user, arity: 1, spec: "get_user(user_id()) :: map()", line: 4}],
      callbacks: [],
      optional_callbacks: [],
      structs: [%{module: "MyApp.Accounts", fields: [:name, :email], line: 2}],
      docs: [%{function: :get_user, arity: 1, doc: "Gets a user by ID.", line: 4}],
      line_count: 20,
      complexity: 3
    }

    Store.put_ast(@test_path, "lib/my_app/accounts.ex", ast_data)

    on_exit(fn -> Store.clear_asts(@test_path) end)

    %{path: @test_path}
  end

  describe "list_modules/1" do
    test "returns all modules", %{path: path} do
      modules = Query.list_modules(path)
      assert length(modules) == 1
      assert hd(modules).name == "MyApp.Accounts"
    end
  end

  describe "find_module/2" do
    test "finds existing module", %{path: path} do
      assert {:ok, %{file: "lib/my_app/accounts.ex"}} = Query.find_module(path, "MyApp.Accounts")
    end

    test "returns :not_found for missing module", %{path: path} do
      assert :not_found = Query.find_module(path, "DoesNotExist")
    end
  end

  describe "find_module_by_file/2" do
    test "finds module by file path", %{path: path} do
      assert {:ok, %{name: "MyApp.Accounts"}} = Query.find_module_by_file(path, "lib/my_app/accounts.ex")
    end
  end

  describe "list_functions/2" do
    test "lists all functions", %{path: path} do
      funcs = Query.list_functions(path, nil)
      assert length(funcs) == 3
    end

    test "filters by module", %{path: path} do
      funcs = Query.list_functions(path, "MyApp.Accounts")
      assert length(funcs) == 3
    end

    test "returns empty for non-existent module", %{path: path} do
      assert Query.list_functions(path, "Nope") == []
    end
  end

  describe "find_function/3" do
    test "finds function by name", %{path: path} do
      results = Query.find_function(path, :get_user, nil)
      assert length(results) == 1
      assert hd(results).arity == 1
    end

    test "filters by arity", %{path: path} do
      assert Query.find_function(path, :get_user, 0) == []
      assert length(Query.find_function(path, :get_user, 1)) == 1
    end
  end

  describe "list_types/2" do
    test "lists types", %{path: path} do
      types = Query.list_types(path, nil)
      assert length(types) >= 1
      assert hd(types).name == :user_id
    end
  end

  describe "list_specs/2" do
    test "lists specs", %{path: path} do
      specs = Query.list_specs(path, nil)
      assert length(specs) >= 1
    end
  end

  describe "get_spec/4" do
    test "finds spec for function", %{path: path} do
      spec = Query.get_spec(path, "MyApp.Accounts", :get_user, 1)
      assert spec.function == :get_user
    end

    test "returns nil for missing spec", %{path: path} do
      assert Query.get_spec(path, "MyApp.Accounts", :validate, 1) == nil
    end
  end

  describe "list_structs/1" do
    test "lists structs", %{path: path} do
      structs = Query.list_structs(path)
      assert length(structs) == 1
      assert :name in hd(structs).fields
    end
  end

  describe "get_struct/2" do
    test "gets struct for module", %{path: path} do
      s = Query.get_struct(path, "MyApp.Accounts")
      assert s.module == "MyApp.Accounts"
    end

    test "returns nil for module without struct", %{path: path} do
      assert Query.get_struct(path, "Nope") == nil
    end
  end

  describe "list_docs/2" do
    test "lists docs", %{path: path} do
      docs = Query.list_docs(path, nil)
      assert length(docs) >= 1
    end
  end

  describe "get_function_doc/4" do
    test "gets doc for function", %{path: path} do
      doc = Query.get_function_doc(path, "MyApp.Accounts", :get_user, 1)
      assert doc.doc =~ "Gets a user"
    end
  end

  describe "get_moduledoc/2" do
    test "gets moduledoc", %{path: path} do
      assert {:ok, "Account management."} = Query.get_moduledoc(path, "MyApp.Accounts")
    end

    test "returns :not_found for missing module", %{path: path} do
      assert :not_found = Query.get_moduledoc(path, "Nope")
    end
  end
end
