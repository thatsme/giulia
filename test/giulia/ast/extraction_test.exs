defmodule Giulia.AST.ExtractionTest do
  use ExUnit.Case, async: true

  alias Giulia.AST.Extraction

  @sample_source """
  defmodule MyApp.Accounts do
    @moduledoc "Manages user accounts."

    use GenServer
    alias MyApp.Repo
    import Ecto.Query

    @type user_id :: non_neg_integer()
    @typep internal :: atom()

    @spec get_user(user_id()) :: map()
    def get_user(id), do: Repo.get(User, id)

    @spec list_users() :: [map()]
    def list_users, do: Repo.all(User)

    defp secret_func, do: :hidden

    @doc "Creates a user."
    def create_user(attrs), do: Repo.insert(attrs)

    defstruct [:name, :email, :age]
  end
  """

  setup_all do
    {:ok, ast} = Sourceror.parse_string(@sample_source)
    %{ast: ast}
  end

  # ============================================================================
  # extract_modules/1
  # ============================================================================

  describe "extract_modules/1" do
    test "finds module definitions", %{ast: ast} do
      modules = Extraction.extract_modules(ast)
      assert length(modules) == 1
      assert hd(modules).name == "MyApp.Accounts"
    end

    test "captures line numbers", %{ast: ast} do
      [mod] = Extraction.extract_modules(ast)
      assert mod.line > 0
    end

    test "extracts moduledoc", %{ast: ast} do
      [mod] = Extraction.extract_modules(ast)
      assert mod.moduledoc == "Manages user accounts."
    end

    test "handles empty AST" do
      assert Extraction.extract_modules({:__block__, [], []}) == []
    end

    test "handles multiple modules" do
      source = """
      defmodule A do end
      defmodule B do end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      modules = Extraction.extract_modules(ast)
      assert length(modules) == 2
      names = Enum.map(modules, & &1.name)
      assert "A" in names
      assert "B" in names
    end
  end

  # ============================================================================
  # extract_functions/1
  # ============================================================================

  describe "extract_functions/1" do
    test "finds public and private functions", %{ast: ast} do
      functions = Extraction.extract_functions(ast)
      names = Enum.map(functions, & &1.name)
      assert :get_user in names
      assert :list_users in names
      assert :secret_func in names
      assert :create_user in names
    end

    test "distinguishes def from defp", %{ast: ast} do
      functions = Extraction.extract_functions(ast)
      get_user = Enum.find(functions, &(&1.name == :get_user))
      secret = Enum.find(functions, &(&1.name == :secret_func))
      assert get_user.type == :def
      assert secret.type == :defp
    end

    test "captures arity", %{ast: ast} do
      functions = Extraction.extract_functions(ast)
      get_user = Enum.find(functions, &(&1.name == :get_user))
      list_users = Enum.find(functions, &(&1.name == :list_users))
      assert get_user.arity == 1
      assert list_users.arity == 0
    end

    test "handles when clause" do
      source = """
      defmodule M do
        def foo(x) when is_integer(x), do: x
      end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      [func] = Extraction.extract_functions(ast)
      assert func.name == :foo
      assert func.arity == 1
    end

    test "handles empty module" do
      {:ok, ast} = Sourceror.parse_string("defmodule Empty do end")
      assert Extraction.extract_functions(ast) == []
    end
  end

  # ============================================================================
  # extract_imports/1
  # ============================================================================

  describe "extract_imports/1" do
    test "finds use, alias, import", %{ast: ast} do
      imports = Extraction.extract_imports(ast)
      types = Enum.map(imports, & &1.type)
      assert :use in types
      assert :alias in types
      assert :import in types
    end

    test "extracts module names", %{ast: ast} do
      imports = Extraction.extract_imports(ast)
      modules = Enum.map(imports, & &1.module)
      assert "GenServer" in modules
      assert "MyApp.Repo" in modules
      assert "Ecto.Query" in modules
    end

    test "handles multi-alias syntax" do
      source = """
      defmodule M do
        alias MyApp.{Foo, Bar, Baz}
      end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      imports = Extraction.extract_imports(ast)
      modules = Enum.map(imports, & &1.module)
      assert "MyApp.Foo" in modules
      assert "MyApp.Bar" in modules
      assert "MyApp.Baz" in modules
    end
  end

  # ============================================================================
  # extract_types/1
  # ============================================================================

  describe "extract_types/1" do
    test "finds type definitions", %{ast: ast} do
      types = Extraction.extract_types(ast)
      assert length(types) >= 1
      names = Enum.map(types, & &1.name)
      assert :user_id in names
    end

    test "captures visibility", %{ast: ast} do
      types = Extraction.extract_types(ast)
      user_id = Enum.find(types, &(&1.name == :user_id))
      internal = Enum.find(types, &(&1.name == :internal))
      assert user_id.visibility == :type
      assert internal.visibility == :typep
    end
  end

  # ============================================================================
  # extract_specs/1
  # ============================================================================

  describe "extract_specs/1" do
    test "finds spec definitions", %{ast: ast} do
      specs = Extraction.extract_specs(ast)
      funcs = Enum.map(specs, & &1.function)
      assert :get_user in funcs
      assert :list_users in funcs
    end

    test "captures arity", %{ast: ast} do
      specs = Extraction.extract_specs(ast)
      get_user = Enum.find(specs, &(&1.function == :get_user))
      assert get_user.arity == 1
    end
  end

  # ============================================================================
  # extract_structs/1
  # ============================================================================

  describe "extract_structs/1" do
    test "finds struct definitions", %{ast: ast} do
      structs = Extraction.extract_structs(ast)
      assert length(structs) == 1
      [s] = structs
      assert :name in s.fields
      assert :email in s.fields
      assert :age in s.fields
    end

    test "associates struct with module", %{ast: ast} do
      [s] = Extraction.extract_structs(ast)
      assert s.module == "MyApp.Accounts"
    end
  end

  # ============================================================================
  # extract_docs/1
  # ============================================================================

  describe "extract_docs/1" do
    test "links docs to functions", %{ast: ast} do
      docs = Extraction.extract_docs(ast)
      assert length(docs) >= 1
      doc = Enum.find(docs, &(&1.function == :create_user))
      assert doc.doc == "Creates a user."
    end
  end

  # ============================================================================
  # extract_callbacks/1
  # ============================================================================

  describe "extract_callbacks/1" do
    test "finds callback definitions" do
      source = """
      defmodule MyBehaviour do
        @callback init(term()) :: {:ok, term()}
        @callback handle(term()) :: :ok
        @optional_callbacks [handle: 1]
      end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      callbacks = Extraction.extract_callbacks(ast)
      assert length(callbacks) == 2

      init_cb = Enum.find(callbacks, &(&1.function == :init))
      handle_cb = Enum.find(callbacks, &(&1.function == :handle))
      assert init_cb.optional == false
      assert handle_cb.optional == true
    end

    test "returns empty for module without callbacks", %{ast: ast} do
      assert Extraction.extract_callbacks(ast) == []
    end
  end

  # ============================================================================
  # extract_moduledoc/1
  # ============================================================================

  describe "extract_moduledoc/1" do
    test "extracts moduledoc string", %{ast: ast} do
      assert Extraction.extract_moduledoc(ast) == "Manages user accounts."
    end

    test "returns nil when no moduledoc" do
      {:ok, ast} = Sourceror.parse_string("defmodule M do end")
      assert Extraction.extract_moduledoc(ast) == nil
    end

    test "returns nil when moduledoc is false" do
      source = """
      defmodule M do
        @moduledoc false
      end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      assert Extraction.extract_moduledoc(ast) == nil
    end
  end
end
