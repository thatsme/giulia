defmodule Giulia.Context.StoreTest do
  @moduledoc """
  Tests for Context.Store — ETS-backed GenServer for project state.

  Context.Store is the core data layer: all AST metadata is stored in ETS,
  namespaced by project_path. Tests use `start_supervised` to get a fresh
  ETS table per test run.

  Note: async: false because ETS table is named and shared.
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Store

  @project "/test/project"

  setup do
    # Start a fresh Store GenServer (creates the ETS table)
    case Process.whereis(Store) do
      nil -> start_supervised!(Store)
      _pid -> :ok
    end

    # Clean up any leftover data from previous tests
    Store.clear_asts(@project)
    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp sample_ast_data do
    %{
      modules: [%{name: "MyApp.Users", line: 1, moduledoc: "User management"}],
      functions: [
        %{name: :create, arity: 1, type: :def, line: 5},
        %{name: :update, arity: 2, type: :def, line: 15},
        %{name: :validate, arity: 1, type: :defp, line: 25}
      ],
      imports: [%{module: "MyApp.Repo", type: :alias, line: 2}],
      structs: [%{module: "MyApp.Users", fields: [:name, :email, :age], line: 3}],
      callbacks: [],
      types: [%{name: :t, arity: 0, line: 4}],
      specs: [%{function: :create, arity: 1, spec: "create(map()) :: {:ok, t()}", line: 4}],
      docs: [%{function: :create, arity: 1, doc: "Creates a new user.", line: 4}]
    }
  end

  defp second_module_ast_data do
    %{
      modules: [%{name: "MyApp.Repo", line: 1, moduledoc: "Database interface"}],
      functions: [
        %{name: :insert, arity: 1, type: :def, line: 3},
        %{name: :get, arity: 2, type: :def, line: 10}
      ],
      imports: [],
      structs: [],
      callbacks: [
        %{function: :init, arity: 1, line: 2}
      ],
      types: [],
      specs: [],
      docs: []
    }
  end

  defp populate_store do
    Store.put_ast(@project, "lib/my_app/users.ex", sample_ast_data())
    Store.put_ast(@project, "lib/my_app/repo.ex", second_module_ast_data())
  end

  # ============================================================================
  # AST Storage: put_ast, get_ast, all_asts, clear_asts
  # ============================================================================

  describe "put_ast/3 and get_ast/2" do
    test "stores and retrieves AST data" do
      data = sample_ast_data()
      assert :ok = Store.put_ast(@project, "lib/users.ex", data)
      assert {:ok, retrieved} = Store.get_ast(@project, "lib/users.ex")
      assert retrieved == data
    end

    test "returns :error for missing file" do
      assert :error = Store.get_ast(@project, "lib/nonexistent.ex")
    end

    test "overwrites existing data" do
      Store.put_ast(@project, "lib/users.ex", %{modules: [%{name: "Old", line: 1}]})
      Store.put_ast(@project, "lib/users.ex", %{modules: [%{name: "New", line: 1}]})
      assert {:ok, data} = Store.get_ast(@project, "lib/users.ex")
      assert [%{name: "New"}] = data.modules
    end
  end

  describe "all_asts/1" do
    test "returns all AST data for project" do
      populate_store()
      all = Store.all_asts(@project)
      assert map_size(all) == 2
      assert Map.has_key?(all, "lib/my_app/users.ex")
      assert Map.has_key?(all, "lib/my_app/repo.ex")
    end

    test "returns empty map for unknown project" do
      assert Store.all_asts("/unknown/project") == %{}
    end
  end

  describe "clear_asts/1" do
    test "removes all AST data for project" do
      populate_store()
      assert map_size(Store.all_asts(@project)) == 2
      Store.clear_asts(@project)
      assert Store.all_asts(@project) == %{}
    end

    test "does not affect other projects" do
      Store.put_ast(@project, "lib/a.ex", %{modules: []})
      Store.put_ast("/other/project", "lib/b.ex", %{modules: []})
      Store.clear_asts(@project)
      assert Store.all_asts(@project) == %{}
      assert map_size(Store.all_asts("/other/project")) == 1
      # Cleanup
      Store.clear_asts("/other/project")
    end
  end

  # ============================================================================
  # Project Files
  # ============================================================================

  describe "put_project_files/2 and get_project_files/1" do
    test "stores and retrieves file list" do
      files = ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
      assert :ok = Store.put_project_files(@project, files)
      assert Store.get_project_files(@project) == files
    end

    test "returns empty list for unknown project" do
      assert Store.get_project_files("/unknown") == []
    end
  end

  # ============================================================================
  # Embeddings
  # ============================================================================

  describe "put_embeddings/3 and get_embeddings/2" do
    test "stores module embeddings" do
      entries = [%{id: "MyApp.Users", vector: <<1, 2, 3>>, metadata: %{}}]
      assert :ok = Store.put_embeddings(@project, :module, entries)
      assert {:ok, retrieved} = Store.get_embeddings(@project, :module)
      assert retrieved == entries
    end

    test "stores function embeddings separately" do
      mod_entries = [%{id: "mod1", vector: <<1>>, metadata: %{}}]
      func_entries = [%{id: "func1", vector: <<2>>, metadata: %{}}]
      Store.put_embeddings(@project, :module, mod_entries)
      Store.put_embeddings(@project, :function, func_entries)

      assert {:ok, mods} = Store.get_embeddings(@project, :module)
      assert {:ok, funcs} = Store.get_embeddings(@project, :function)
      assert mods != funcs
    end

    test "returns :error for missing embeddings" do
      assert :error = Store.get_embeddings(@project, :module)
    end
  end

  describe "clear_embeddings/1" do
    test "removes both module and function embeddings" do
      Store.put_embeddings(@project, :module, [%{id: "m", vector: <<>>, metadata: %{}}])
      Store.put_embeddings(@project, :function, [%{id: "f", vector: <<>>, metadata: %{}}])
      Store.clear_embeddings(@project)
      assert :error = Store.get_embeddings(@project, :module)
      assert :error = Store.get_embeddings(@project, :function)
    end
  end

  # ============================================================================
  # Generic KV: put/2, get/1, delete/1
  # ============================================================================

  describe "generic put/get/delete" do
    test "stores and retrieves arbitrary data" do
      Store.put(:my_key, "my_value")
      assert {:ok, "my_value"} = Store.get(:my_key)
      Store.delete(:my_key)
    end

    test "returns :error for missing key" do
      assert :error = Store.get(:nonexistent_key)
    end

    test "delete removes key" do
      Store.put(:temp_key, 42)
      Store.delete(:temp_key)
      assert :error = Store.get(:temp_key)
    end
  end

  # ============================================================================
  # Stats
  # ============================================================================

  describe "stats/1" do
    test "returns file count and total entries" do
      populate_store()
      stats = Store.stats(@project)
      assert stats.ast_files == 2
      assert stats.total_entries >= 2
    end

    test "zero files for empty project" do
      stats = Store.stats(@project)
      assert stats.ast_files == 0
    end
  end

  # ============================================================================
  # Query Interface: list_modules
  # ============================================================================

  describe "list_modules/1" do
    test "lists all modules sorted by name" do
      populate_store()
      modules = Store.list_modules(@project)
      assert length(modules) == 2
      names = Enum.map(modules, & &1.name)
      assert "MyApp.Repo" in names
      assert "MyApp.Users" in names
      # Should be sorted
      assert names == Enum.sort(names)
    end

    test "returns empty list for empty project" do
      assert Store.list_modules(@project) == []
    end

    test "includes file and line info" do
      populate_store()
      mod = Enum.find(Store.list_modules(@project), &(&1.name == "MyApp.Users"))
      assert mod.file == "lib/my_app/users.ex"
      assert mod.line == 1
    end
  end

  # ============================================================================
  # Query Interface: list_functions
  # ============================================================================

  describe "list_functions/2" do
    test "lists all functions across all modules" do
      populate_store()
      funcs = Store.list_functions(@project)
      # Users has 3, Repo has 2 = 5 total
      assert length(funcs) == 5
    end

    test "filters by module name" do
      populate_store()
      funcs = Store.list_functions(@project, "MyApp.Users")
      assert length(funcs) == 3
      assert Enum.all?(funcs, &(&1.module == "MyApp.Users"))
    end

    test "returns empty for unknown module" do
      populate_store()
      assert Store.list_functions(@project, "NonExistent") == []
    end

    test "includes type information" do
      populate_store()
      funcs = Store.list_functions(@project, "MyApp.Users")
      public = Enum.filter(funcs, &(&1.type == :def))
      private = Enum.filter(funcs, &(&1.type == :defp))
      assert length(public) == 2
      assert length(private) == 1
    end
  end

  # ============================================================================
  # Query Interface: find_module, find_function
  # ============================================================================

  describe "find_module/2" do
    test "finds module by name" do
      populate_store()
      assert {:ok, result} = Store.find_module(@project, "MyApp.Users")
      assert result.file == "lib/my_app/users.ex"
      assert is_map(result.ast_data)
    end

    test "returns :not_found for unknown module" do
      populate_store()
      assert :not_found = Store.find_module(@project, "Unknown")
    end
  end

  describe "find_function/3" do
    test "finds function by name across all modules" do
      populate_store()
      results = Store.find_function(@project, :create)
      assert length(results) == 1
      assert hd(results).module == "MyApp.Users"
    end

    test "finds function filtered by arity" do
      populate_store()
      results = Store.find_function(@project, :create, 1)
      assert length(results) == 1

      results = Store.find_function(@project, :create, 99)
      assert results == []
    end

    test "returns empty list for unknown function" do
      populate_store()
      assert Store.find_function(@project, :nonexistent) == []
    end
  end

  # ============================================================================
  # Query Interface: find_module_by_file
  # ============================================================================

  describe "find_module_by_file/2" do
    test "finds module by file path" do
      populate_store()
      assert {:ok, %{name: "MyApp.Users"}} =
               Store.find_module_by_file(@project, "lib/my_app/users.ex")
    end

    test "handles path with different separators" do
      populate_store()
      # Backslash should still match
      assert {:ok, %{name: "MyApp.Users"}} =
               Store.find_module_by_file(@project, "lib\\my_app\\users.ex")
    end

    test "returns :not_found for unknown file" do
      populate_store()
      assert :not_found = Store.find_module_by_file(@project, "lib/unknown.ex")
    end
  end

  # ============================================================================
  # Query Interface: Types, Specs, Callbacks, Structs, Docs
  # ============================================================================

  describe "list_types/2" do
    test "lists all types" do
      populate_store()
      types = Store.list_types(@project)
      assert length(types) >= 1
      assert Enum.any?(types, &(&1.name == :t))
    end

    test "filters by module" do
      populate_store()
      types = Store.list_types(@project, "MyApp.Users")
      assert length(types) == 1
      assert Store.list_types(@project, "MyApp.Repo") == []
    end
  end

  describe "list_specs/2" do
    test "lists all specs" do
      populate_store()
      specs = Store.list_specs(@project)
      assert length(specs) >= 1
    end

    test "filters by module" do
      populate_store()
      specs = Store.list_specs(@project, "MyApp.Users")
      assert length(specs) == 1
      assert hd(specs).function == :create
    end
  end

  describe "get_spec/4" do
    test "finds spec for specific function" do
      populate_store()
      spec = Store.get_spec(@project, "MyApp.Users", :create, 1)
      assert spec != nil
      assert spec.function == :create
    end

    test "returns nil for missing spec" do
      populate_store()
      assert Store.get_spec(@project, "MyApp.Users", :nonexistent, 0) == nil
    end
  end

  describe "list_callbacks/2" do
    test "lists all callbacks" do
      populate_store()
      callbacks = Store.list_callbacks(@project)
      assert length(callbacks) >= 1
      assert Enum.any?(callbacks, &(&1.function == :init))
    end

    test "filters by module" do
      populate_store()
      cbs = Store.list_callbacks(@project, "MyApp.Repo")
      assert length(cbs) == 1
      assert Store.list_callbacks(@project, "MyApp.Users") == []
    end
  end

  describe "list_structs/1 and get_struct/2" do
    test "lists all structs" do
      populate_store()
      structs = Store.list_structs(@project)
      assert length(structs) >= 1
      assert Enum.any?(structs, &(&1.module == "MyApp.Users"))
    end

    test "gets specific struct" do
      populate_store()
      struct = Store.get_struct(@project, "MyApp.Users")
      assert struct != nil
      assert :name in struct.fields
      assert :email in struct.fields
    end

    test "returns nil for module without struct" do
      populate_store()
      assert Store.get_struct(@project, "MyApp.Repo") == nil
    end
  end

  describe "list_docs/2 and get_function_doc/4" do
    test "lists all docs" do
      populate_store()
      docs = Store.list_docs(@project)
      assert length(docs) >= 1
    end

    test "gets doc for specific function" do
      populate_store()
      doc = Store.get_function_doc(@project, "MyApp.Users", :create, 1)
      assert doc != nil
      assert doc.doc == "Creates a new user."
    end

    test "returns nil for undocumented function" do
      populate_store()
      assert Store.get_function_doc(@project, "MyApp.Users", :update, 2) == nil
    end
  end

  # ============================================================================
  # Query Interface: Moduledoc
  # ============================================================================

  describe "get_moduledoc/2" do
    test "returns moduledoc for module" do
      populate_store()
      assert {:ok, doc} = Store.get_moduledoc(@project, "MyApp.Users")
      assert doc == "User management"
    end

    test "returns :not_found for module without moduledoc" do
      data = %{
        modules: [%{name: "NoDoc", line: 1}],
        functions: [],
        imports: [],
        structs: [],
        callbacks: [],
        types: [],
        specs: [],
        docs: []
      }
      Store.put_ast(@project, "lib/no_doc.ex", data)
      assert :not_found = Store.get_moduledoc(@project, "NoDoc")
    end

    test "returns :not_found for unknown module" do
      assert :not_found = Store.get_moduledoc(@project, "Unknown")
    end
  end

  # ============================================================================
  # Project Summary
  # ============================================================================

  describe "project_summary/1" do
    test "returns formatted summary string" do
      populate_store()
      summary = Store.project_summary(@project)
      assert is_binary(summary)
      assert summary =~ "PROJECT INDEX"
      assert summary =~ "Modules: 2"
      assert summary =~ "MyApp.Users"
      assert summary =~ "MyApp.Repo"
    end

    test "empty project returns summary with zeroes" do
      summary = Store.project_summary(@project)
      assert summary =~ "Files: 0"
      assert summary =~ "Modules: 0"
    end
  end

  # ============================================================================
  # Module Details
  # ============================================================================

  describe "module_details/2" do
    test "returns detailed summary for known module" do
      populate_store()
      details = Store.module_details(@project, "MyApp.Users")
      assert details =~ "MyApp.Users"
      assert details =~ "create/1"
      assert details =~ "validate/1"
      assert details =~ "Public functions"
      assert details =~ "Private functions"
    end

    test "returns not-found message for unknown module" do
      details = Store.module_details(@project, "Unknown")
      assert details =~ "not found"
    end
  end

  # ============================================================================
  # Multi-project isolation
  # ============================================================================

  describe "multi-project isolation" do
    test "data for different projects is isolated" do
      project_a = "/project/alpha"
      project_b = "/project/beta"

      Store.put_ast(project_a, "lib/a.ex", %{modules: [%{name: "Alpha", line: 1}], functions: [], imports: [], structs: [], callbacks: [], types: [], specs: [], docs: []})
      Store.put_ast(project_b, "lib/b.ex", %{modules: [%{name: "Beta", line: 1}], functions: [], imports: [], structs: [], callbacks: [], types: [], specs: [], docs: []})

      a_modules = Store.list_modules(project_a)
      b_modules = Store.list_modules(project_b)

      assert length(a_modules) == 1
      assert hd(a_modules).name == "Alpha"
      assert length(b_modules) == 1
      assert hd(b_modules).name == "Beta"

      # Cleanup
      Store.clear_asts(project_a)
      Store.clear_asts(project_b)
    end
  end
end
