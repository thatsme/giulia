defmodule Giulia.AST.ProcessorTest do
  @moduledoc """
  Tests for the Sourceror-based AST processor.

  AST.Processor is the parsing engine — everything that analyzes Elixir
  code depends on it. These tests prove:

  1. Parsing: source → AST round-trip works
  2. Module extraction: defmodule nodes are found with name + line + moduledoc
  3. Function extraction: def/defp with arity, guards, line numbers
  4. Import extraction: alias, use, require, import, @behaviour, multi-module
  5. Type/spec/callback extraction
  6. Struct extraction: defstruct fields
  7. Doc extraction: @doc linked to next function
  8. Complexity estimation: control flow nodes counted
  9. Code slicing: function isolation for small-model context
  10. Code patching: function replacement in source

  All tests use inline Elixir source strings — no file I/O, fully deterministic.
  """
  use ExUnit.Case, async: true

  alias Giulia.AST.Processor

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  @simple_module """
  defmodule MyApp.Greeter do
    @moduledoc "A simple greeter module."

    def hello(name), do: "Hello, \#{name}!"

    defp secret, do: :classified
  end
  """

  @multi_module """
  defmodule MyApp.Alpha do
    def alpha, do: :a
  end

  defmodule MyApp.Beta do
    def beta, do: :b
  end
  """

  @complex_module """
  defmodule MyApp.Complex do
    @moduledoc "Complex module for testing."

    alias MyApp.Helper
    import Enum, only: [map: 2]
    use GenServer
    require Logger

    @type state :: map()
    @type result :: {:ok, term()} | {:error, term()}

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @doc "Initialize the server state."
    @spec init(keyword()) :: {:ok, map()}
    def init(opts) do
      {:ok, Map.new(opts)}
    end

    defp handle_internal(data) do
      case data do
        nil -> {:error, :no_data}
        _ ->
          if valid?(data) do
            {:ok, data}
          else
            {:error, :invalid}
          end
      end
    end

    defp valid?(_data), do: true
  end
  """

  @struct_module """
  defmodule MyApp.User do
    defstruct [:name, :email, :age]

    def new(name, email) do
      %__MODULE__{name: name, email: email, age: 0}
    end
  end
  """

  @guarded_module """
  defmodule MyApp.Guard do
    def process(x) when is_integer(x), do: x * 2
    def process(x) when is_binary(x), do: String.length(x)
    defp validate(x) when is_map(x), do: {:ok, x}
  end
  """

  @callback_module """
  defmodule MyApp.Behaviour do
    @callback handle_event(term()) :: :ok | {:error, term()}
    @callback init(keyword()) :: {:ok, term()}
  end
  """

  @multi_alias_module """
  defmodule MyApp.MultiAlias do
    alias MyApp.Core.{ContextManager, PathMapper, PathSandbox}

    def foo, do: :ok
  end
  """

  # ============================================================================
  # Section 1: Parsing
  # ============================================================================

  describe "parse/1" do
    test "parses valid Elixir source" do
      assert {:ok, ast, source} = Processor.parse(@simple_module)
      assert is_tuple(ast)
      assert source == @simple_module
    end

    test "returns error for invalid source" do
      assert {:error, _reason} = Processor.parse("def broken(, do: end")
    end

    test "preserves original source in return" do
      assert {:ok, _ast, source} = Processor.parse(@simple_module)
      assert source == @simple_module
    end
  end

  # ============================================================================
  # Section 2: Module Extraction
  # ============================================================================

  describe "extract_modules/1" do
    test "extracts single module" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      modules = Processor.extract_modules(ast)

      assert length(modules) == 1
      assert hd(modules).name == "MyApp.Greeter"
    end

    test "extracts module line number" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      [module] = Processor.extract_modules(ast)

      assert module.line == 1
    end

    test "extracts moduledoc" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      [module] = Processor.extract_modules(ast)

      assert module.moduledoc == "A simple greeter module."
    end

    test "extracts multiple modules from same file" do
      {:ok, ast, _} = Processor.parse(@multi_module)
      modules = Processor.extract_modules(ast)

      assert length(modules) == 2
      names = Enum.map(modules, & &1.name)
      assert "MyApp.Alpha" in names
      assert "MyApp.Beta" in names
    end

    test "returns empty list for non-module source" do
      {:ok, ast, _} = Processor.parse("x = 1 + 2")
      assert Processor.extract_modules(ast) == []
    end
  end

  # ============================================================================
  # Section 3: Function Extraction
  # ============================================================================

  describe "extract_functions/1" do
    test "extracts public and private functions" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      functions = Processor.extract_functions(ast)

      names = Enum.map(functions, & &1.name)
      assert :hello in names
      assert :secret in names
    end

    test "distinguishes def from defp" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      functions = Processor.extract_functions(ast)

      hello = Enum.find(functions, &(&1.name == :hello))
      secret = Enum.find(functions, &(&1.name == :secret))

      assert hello.type == :def
      assert secret.type == :defp
    end

    test "extracts correct arity" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      functions = Processor.extract_functions(ast)

      hello = Enum.find(functions, &(&1.name == :hello))
      secret = Enum.find(functions, &(&1.name == :secret))

      assert hello.arity == 1
      assert secret.arity == 0
    end

    test "extracts line numbers" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      functions = Processor.extract_functions(ast)

      Enum.each(functions, fn func ->
        assert func.line > 0
      end)
    end

    test "handles guarded functions" do
      {:ok, ast, _} = Processor.parse(@guarded_module)
      functions = Processor.extract_functions(ast)

      process_funcs = Enum.filter(functions, &(&1.name == :process))
      # Should deduplicate by name/arity
      assert length(process_funcs) == 1
      assert hd(process_funcs).arity == 1
    end

    test "deduplicates multi-clause functions" do
      {:ok, ast, _} = Processor.parse(@guarded_module)
      functions = Processor.extract_functions(ast)

      # process/1 appears twice (two clauses) but should be deduplicated
      process_count = Enum.count(functions, &(&1.name == :process))
      assert process_count == 1
    end
  end

  # ============================================================================
  # Section 4: Import Extraction
  # ============================================================================

  describe "extract_imports/1" do
    test "extracts alias directives" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      imports = Processor.extract_imports(ast)

      aliases = Enum.filter(imports, &(&1.type == :alias))
      assert Enum.any?(aliases, &(&1.module == "MyApp.Helper"))
    end

    test "extracts use directives" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      imports = Processor.extract_imports(ast)

      uses = Enum.filter(imports, &(&1.type == :use))
      assert Enum.any?(uses, &(&1.module == "GenServer"))
    end

    test "extracts require directives" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      imports = Processor.extract_imports(ast)

      requires = Enum.filter(imports, &(&1.type == :require))
      assert Enum.any?(requires, &(&1.module == "Logger"))
    end

    test "extracts import directives" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      imports = Processor.extract_imports(ast)

      import_directives = Enum.filter(imports, &(&1.type == :import))
      assert Enum.any?(import_directives, &(&1.module == "Enum"))
    end

    test "expands multi-module alias syntax" do
      {:ok, ast, _} = Processor.parse(@multi_alias_module)
      imports = Processor.extract_imports(ast)

      modules = Enum.map(imports, & &1.module)
      assert "MyApp.Core.ContextManager" in modules
      assert "MyApp.Core.PathMapper" in modules
      assert "MyApp.Core.PathSandbox" in modules
    end

    test "extracts line numbers for imports" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      imports = Processor.extract_imports(ast)

      Enum.each(imports, fn imp ->
        assert imp.line > 0
      end)
    end
  end

  # ============================================================================
  # Section 5: Type Extraction
  # ============================================================================

  describe "extract_types/1" do
    test "extracts @type definitions" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      types = Processor.extract_types(ast)

      type_names = Enum.map(types, & &1.name)
      assert :state in type_names
      assert :result in type_names
    end

    test "captures type visibility" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      types = Processor.extract_types(ast)

      Enum.each(types, fn type ->
        assert type.visibility in [:type, :typep, :opaque]
      end)
    end
  end

  # ============================================================================
  # Section 6: Spec Extraction
  # ============================================================================

  describe "extract_specs/1" do
    test "extracts @spec definitions" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      specs = Processor.extract_specs(ast)

      spec_functions = Enum.map(specs, & &1.function)
      assert :start_link in spec_functions
      assert :init in spec_functions
    end

    test "captures spec arity" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      specs = Processor.extract_specs(ast)

      start_link_spec = Enum.find(specs, &(&1.function == :start_link))
      assert start_link_spec.arity == 1
    end

    test "captures spec string representation" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      specs = Processor.extract_specs(ast)

      Enum.each(specs, fn spec ->
        assert is_binary(spec.spec)
        assert String.length(spec.spec) > 0
      end)
    end
  end

  # ============================================================================
  # Section 7: Callback Extraction
  # ============================================================================

  describe "extract_callbacks/1" do
    test "extracts @callback definitions" do
      {:ok, ast, _} = Processor.parse(@callback_module)
      callbacks = Processor.extract_callbacks(ast)

      callback_names = Enum.map(callbacks, & &1.function)
      assert :handle_event in callback_names
      assert :init in callback_names
    end

    test "captures callback arity" do
      {:ok, ast, _} = Processor.parse(@callback_module)
      callbacks = Processor.extract_callbacks(ast)

      handle = Enum.find(callbacks, &(&1.function == :handle_event))
      assert handle.arity == 1
    end
  end

  # ============================================================================
  # Section 8: Struct Extraction
  # ============================================================================

  describe "extract_structs/1" do
    test "extracts defstruct fields" do
      {:ok, ast, _} = Processor.parse(@struct_module)
      structs = Processor.extract_structs(ast)

      assert length(structs) == 1
      [struct] = structs
      assert :name in struct.fields
      assert :email in struct.fields
      assert :age in struct.fields
    end

    test "associates struct with its module" do
      {:ok, ast, _} = Processor.parse(@struct_module)
      [struct] = Processor.extract_structs(ast)

      assert struct.module == "MyApp.User"
    end
  end

  # ============================================================================
  # Section 9: Doc Extraction
  # ============================================================================

  describe "extract_docs/1" do
    test "extracts @doc and links to function" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      docs = Processor.extract_docs(ast)

      init_doc = Enum.find(docs, &(&1.function == :init))
      assert init_doc != nil
      assert init_doc.doc =~ "Initialize"
    end

    test "captures doc line number" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      docs = Processor.extract_docs(ast)

      Enum.each(docs, fn doc ->
        assert doc.line > 0
      end)
    end
  end

  # ============================================================================
  # Section 10: Complexity Estimation
  # ============================================================================

  describe "estimate_complexity/1" do
    test "simple module has low complexity" do
      {:ok, ast, _} = Processor.parse(@simple_module)
      complexity = Processor.estimate_complexity(ast)

      # 2 function defs = complexity 2
      assert complexity >= 2
    end

    test "complex module has higher complexity" do
      {:ok, ast, _} = Processor.parse(@complex_module)
      complexity = Processor.estimate_complexity(ast)

      # Has case, if, def, defp — should be higher
      assert complexity > 4
    end

    test "empty source has zero complexity" do
      {:ok, ast, _} = Processor.parse("x = 1")
      complexity = Processor.estimate_complexity(ast)

      assert complexity == 0
    end
  end

  # ============================================================================
  # Section 11: analyze/2 — Full File Analysis
  # ============================================================================

  describe "analyze/2" do
    test "returns complete file_info map" do
      {:ok, ast, source} = Processor.parse(@complex_module)
      info = Processor.analyze(ast, source)

      assert is_map(info)
      assert Map.has_key?(info, :modules)
      assert Map.has_key?(info, :functions)
      assert Map.has_key?(info, :imports)
      assert Map.has_key?(info, :types)
      assert Map.has_key?(info, :specs)
      assert Map.has_key?(info, :callbacks)
      assert Map.has_key?(info, :structs)
      assert Map.has_key?(info, :docs)
      assert Map.has_key?(info, :line_count)
      assert Map.has_key?(info, :complexity)
    end

    test "line_count matches source" do
      {:ok, ast, source} = Processor.parse(@complex_module)
      info = Processor.analyze(ast, source)

      expected_lines = source |> String.split("\n") |> length()
      assert info.line_count == expected_lines
    end
  end

  # ============================================================================
  # Section 12: count_lines/1
  # ============================================================================

  describe "count_lines/1" do
    test "counts lines in source string" do
      assert Processor.count_lines("a\nb\nc") == 3
    end

    test "single line" do
      assert Processor.count_lines("hello") == 1
    end

    test "returns 0 for non-string input" do
      assert Processor.count_lines(nil) == 0
      assert Processor.count_lines(42) == 0
    end
  end

  # ============================================================================
  # Section 13: slice_function/3 — Function Isolation
  # ============================================================================

  describe "slice_function/3" do
    test "extracts a specific function by name and arity" do
      assert {:ok, func_source} = Processor.slice_function(@simple_module, :hello, 1)
      assert func_source =~ "hello"
    end

    test "returns error for non-existent function" do
      assert {:error, :function_not_found} =
               Processor.slice_function(@simple_module, :nonexistent, 0)
    end

    test "matches on arity" do
      source = """
      defmodule Foo do
        def bar, do: :zero
        def bar(x), do: x
      end
      """

      assert {:ok, func_source} = Processor.slice_function(source, :bar, 1)
      assert func_source =~ "x"
    end
  end

  # ============================================================================
  # Section 14: slice_around_line/3
  # ============================================================================

  describe "slice_around_line/3" do
    test "returns context around target line" do
      source = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end)
      result = Processor.slice_around_line(source, 10, 3)

      assert is_binary(result)
      assert result =~ ">>>"  # Marker for target line
      assert result =~ "10:"
    end

    test "handles line near start of file" do
      source = Enum.map_join(1..5, "\n", fn i -> "line #{i}" end)
      result = Processor.slice_around_line(source, 1, 3)

      assert is_binary(result)
      assert result =~ "1:"
    end

    test "handles line near end of file" do
      source = Enum.map_join(1..5, "\n", fn i -> "line #{i}" end)
      result = Processor.slice_around_line(source, 5, 3)

      assert is_binary(result)
      assert result =~ "5:"
    end

    test "returns empty string for non-string input" do
      assert Processor.slice_around_line(nil, 1, 3) == ""
    end
  end

  # ============================================================================
  # Section 15: summarize/1 and detailed_summary/1
  # ============================================================================

  describe "summarize/1" do
    test "generates compact summary string" do
      {:ok, ast, source} = Processor.parse(@simple_module)
      info = Processor.analyze(ast, source)
      summary = Processor.summarize(info)

      assert is_binary(summary)
      assert summary =~ "MyApp.Greeter"
      assert summary =~ "hello/1"
    end
  end

  describe "detailed_summary/1" do
    test "generates verbose summary with visibility" do
      {:ok, ast, source} = Processor.parse(@simple_module)
      info = Processor.analyze(ast, source)
      summary = Processor.detailed_summary(info)

      assert is_binary(summary)
      assert summary =~ "public"
      assert summary =~ "private"
      assert summary =~ "Complexity"
    end
  end

  # ============================================================================
  # Section 16: extract_moduledoc/1
  # ============================================================================

  describe "extract_moduledoc/1" do
    test "extracts heredoc moduledoc string" do
      source = ~S'''
      defmodule MyApp.Documented do
        @moduledoc """
        A documented module.
        """

        def foo, do: :ok
      end
      '''

      {:ok, ast, _} = Processor.parse(source)
      doc = Processor.extract_moduledoc(ast)

      assert doc != nil
      assert doc =~ "documented module"
    end

    test "returns nil for module without moduledoc" do
      source = """
      defmodule MyApp.NoDocs do
        def foo, do: :ok
      end
      """

      {:ok, ast, _} = Processor.parse(source)
      assert Processor.extract_moduledoc(ast) == nil
    end

    test "returns nil for @moduledoc false" do
      source = """
      defmodule MyApp.Hidden do
        @moduledoc false
        def foo, do: :ok
      end
      """

      {:ok, ast, _} = Processor.parse(source)
      assert Processor.extract_moduledoc(ast) == nil
    end
  end
end
