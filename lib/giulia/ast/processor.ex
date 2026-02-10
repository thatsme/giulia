defmodule Giulia.AST.Processor do
  @moduledoc """
  Native Elixir AST analysis using Sourceror.

  Sourceror preserves comments and formatting, enabling:
  - Accurate code analysis
  - Clean code patching (modify and write back)
  - No C dependencies (pure Elixir)

  This is better than tree-sitter for Elixir-focused work because
  we can write code back while preserving style.
  """

  @type ast :: Macro.t()
  @type parse_result :: {:ok, ast(), String.t()} | {:error, term()}

  @type file_info :: %{
          path: String.t(),
          modules: [module_info()],
          functions: [function_info()],
          imports: [import_info()],
          types: [type_info()],
          specs: [spec_info()],
          callbacks: [callback_info()],
          structs: [struct_info()],
          docs: [doc_info()],
          line_count: non_neg_integer(),
          complexity: non_neg_integer()
        }

  @type module_info :: %{name: String.t(), line: non_neg_integer(), moduledoc: String.t() | nil}
  @type function_info :: %{name: atom(), arity: non_neg_integer(), type: :def | :defp, line: non_neg_integer()}
  @type import_info :: %{type: :import | :alias | :use | :require, module: String.t(), line: non_neg_integer()}
  @type type_info :: %{name: atom(), arity: non_neg_integer(), visibility: :type | :typep | :opaque, line: non_neg_integer(), definition: String.t()}
  @type spec_info :: %{function: atom(), arity: non_neg_integer(), spec: String.t(), line: non_neg_integer()}
  @type callback_info :: %{function: atom(), arity: non_neg_integer(), spec: String.t(), optional: boolean(), line: non_neg_integer()}
  @type struct_info :: %{module: String.t(), fields: [atom()], line: non_neg_integer()}
  @type doc_info :: %{function: atom(), arity: non_neg_integer(), doc: String.t(), line: non_neg_integer()}

  # ============================================================================
  # Debug / Testing
  # ============================================================================

  @doc """
  Quick test function to verify extraction works.
  Call from iex: Giulia.AST.Processor.test_extraction()
  """
  @spec test_extraction() :: %{modules: [module_info()], functions: [function_info()]} | {:error, term()}
  def test_extraction do
    require Logger

    # Simple Elixir module source
    source = """
    defmodule TestModule do
      def hello(name), do: "Hello, \#{name}!"

      defp private_func, do: :ok
    end
    """

    Logger.info("=== TEST EXTRACTION ===")
    Logger.info("Parsing source...")

    case parse(source) do
      {:ok, ast, _src} ->
        Logger.info("AST parsed successfully")
        Logger.info("AST structure: #{inspect(ast, pretty: true, limit: 5)}")

        # Direct pattern match test
        Logger.info("=== DIRECT PATTERN MATCH TEST ===")
        case ast do
          {:defmodule, _meta, [{:__aliases__, _, parts} | _]} ->
            Logger.info("DIRECT MATCH SUCCESS: defmodule with aliases #{inspect(parts)}")
          {:defmodule, _meta, args} ->
            Logger.info("DIRECT MATCH PARTIAL: defmodule but args = #{inspect(args, limit: 3)}")
          other ->
            Logger.info("DIRECT MATCH FAILED: top level is #{inspect(other, limit: 3)}")
        end

        modules = extract_modules(ast)
        functions = extract_functions(ast)

        Logger.info("Extracted #{length(modules)} modules: #{inspect(modules)}")
        Logger.info("Extracted #{length(functions)} functions: #{inspect(functions)}")

        %{modules: modules, functions: functions}

      {:error, reason} ->
        Logger.error("Parse failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Debug function to analyze a real file and show AST structure.
  """
  @spec debug_file(String.t()) :: %{modules: [module_info()], functions: [function_info()]} | {:error, :parse_failed | :read_failed}
  def debug_file(path) do
    require Logger

    Logger.info("=== DEBUG FILE: #{path} ===")

    case File.read(path) do
      {:ok, source} ->
        Logger.info("File read OK, #{byte_size(source)} bytes")

        case Sourceror.parse_string(source) do
          {:ok, ast} ->
            Logger.info("Parse OK")

            # Show top-level structure
            case ast do
              {:__block__, _, children} when is_list(children) ->
                Logger.info("TOP: __block__ with #{length(children)} children")
                Enum.each(Enum.take(children, 3), fn child ->
                  case child do
                    {type, _, _} -> Logger.info("  Child: #{type}")
                    _ -> Logger.info("  Child: #{inspect(child, limit: 2)}")
                  end
                end)

              {type, meta, args} ->
                Logger.info("TOP: #{type} with #{length(args || [])} args")
                Logger.info("  Meta: #{inspect(meta, limit: 5)}")

              other ->
                Logger.info("TOP: unexpected #{inspect(other, limit: 3)}")
            end

            # Now extract
            modules = extract_modules(ast)
            functions = extract_functions(ast)

            %{modules: modules, functions: functions}

          {:error, reason} ->
            Logger.error("Parse failed: #{inspect(reason)}")
            {:error, :parse_failed}
        end

      {:error, reason} ->
        Logger.error("File read failed: #{inspect(reason)}")
        {:error, :read_failed}
    end
  end

  # ============================================================================
  # Parsing
  # ============================================================================

  @doc """
  Parse Elixir source code using Sourceror.
  Returns {:ok, ast, source} or {:error, reason}.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(source) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> {:ok, ast, source}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parse a file from disk.
  """
  @spec parse_file(String.t()) :: parse_result()
  def parse_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source) do
      {:ok, ast, source}
    end
  end

  # ============================================================================
  # Analysis
  # ============================================================================

  @doc """
  Analyze an AST and extract structured metadata.
  """
  @spec analyze(ast(), String.t()) :: file_info()
  def analyze(ast, source) do
    require Logger

    # DEBUG: Show what kind of AST we received (just the type, not full content)
    ast_type = case ast do
      {type, _meta, _args} when is_atom(type) -> "3-tuple with type: #{type}"
      {type, _meta, _args, _extra} -> "4-tuple with type: #{type}"
      list when is_list(list) -> "list with #{length(list)} elements"
      other -> "unexpected: #{inspect(other, limit: 2)}"
    end
    Logger.info("ANALYZE: AST is #{ast_type}")

    # If it's a defmodule, show its structure
    case ast do
      {:defmodule, _meta, args} when is_list(args) ->
        Logger.info("ANALYZE: defmodule has #{length(args)} args")
        case args do
          [first | _] ->
            Logger.info("ANALYZE: first arg = #{inspect(first, limit: 3)}")
          _ ->
            Logger.info("ANALYZE: no args")
        end
      _ ->
        :ok
    end

    modules = extract_modules(ast)
    Logger.info("ANALYZE: got #{length(modules)} modules")

    functions = extract_functions(ast)
    Logger.info("ANALYZE: got #{length(functions)} functions")

    types = extract_types(ast)
    specs = extract_specs(ast)
    callbacks = extract_callbacks(ast)
    optional_callbacks = extract_optional_callbacks(ast)
    structs = extract_structs(ast)
    docs = extract_docs(ast)

    %{
      modules: modules,
      functions: functions,
      imports: extract_imports(ast),
      types: types,
      specs: specs,
      callbacks: callbacks,
      optional_callbacks: MapSet.to_list(optional_callbacks),
      structs: structs,
      docs: docs,
      line_count: safe_count_lines(source),
      complexity: estimate_complexity(ast)
    }
  end

  defp safe_count_lines(source) when is_binary(source) do
    source |> String.split("\n") |> length()
  end

  defp safe_count_lines(_), do: 0

  @doc """
  Analyze a file and return structured metadata.
  """
  @spec analyze_file(String.t()) :: {:ok, file_info()} | {:error, term()}
  def analyze_file(path) do
    with {:ok, ast, source} <- parse_file(path) do
      info = analyze(ast, source) |> Map.put(:path, path)
      {:ok, info}
    end
  end

  @doc """
  Extract module definitions from AST using Macro.prewalk (not Sourceror.prewalk).
  """
  @spec extract_modules(ast()) :: [module_info()]
  def extract_modules(ast) do
    require Logger

    try do
      # Use Macro.prewalk instead of Sourceror.prewalk
      {_ast, modules} = Macro.prewalk(ast, [], fn node, acc ->
        case safe_extract_module_info(node) do
          {:ok, module_info} ->
            Logger.info("FOUND MODULE: #{inspect(module_info)}")
            {node, [module_info | acc]}
          :skip ->
            {node, acc}
        end
      end)

      result = Enum.reverse(modules)
      Logger.info("extract_modules found #{length(result)} modules")
      result
    rescue
      e ->
        Logger.error("extract_modules rescue: #{Exception.message(e)}")
        []
    catch
      kind, reason ->
        Logger.error("extract_modules catch: #{kind} - #{inspect(reason)}")
        []
    end
  end

  # Safe wrapper that never crashes
  defp safe_extract_module_info(node) do
    try do
      extract_module_info(node)
    rescue
      _ -> :skip
    catch
      _, _ -> :skip
    end
  end

  # Extract module info from various AST patterns
  defp extract_module_info({:defmodule, meta, [{:__aliases__, _, parts} | rest]}) when is_list(parts) do
    moduledoc = extract_moduledoc_from_body(rest)
    {:ok, %{
      name: parts |> Enum.map(&to_string/1) |> Enum.join("."),
      line: Keyword.get(meta, :line, 0),
      moduledoc: moduledoc
    }}
  end

  # Handle atom module names (e.g., defmodule :SomeAtom do)
  defp extract_module_info({:defmodule, meta, [module_atom | rest]}) when is_atom(module_atom) do
    moduledoc = extract_moduledoc_from_body(rest)
    {:ok, %{
      name: Atom.to_string(module_atom),
      line: Keyword.get(meta, :line, 0),
      moduledoc: moduledoc
    }}
  end

  # Handle interpolated or dynamic module names - skip these
  defp extract_module_info({:defmodule, _meta, _args}), do: :skip

  # Not a defmodule node
  defp extract_module_info(_), do: :skip

  # Extract @moduledoc from module body
  # Handle standard Code.string_to_quoted format
  defp extract_moduledoc_from_body([[do: body]]) do
    extract_moduledoc_from_ast(body)
  end

  defp extract_moduledoc_from_body([_, [do: body]]) do
    extract_moduledoc_from_ast(body)
  end

  # Handle Sourceror format: [[{key_block, body_block}]]
  defp extract_moduledoc_from_body([[{_key_ast, body_ast}]]) do
    extract_moduledoc_from_ast(body_ast)
  end

  defp extract_moduledoc_from_body(_), do: nil

  defp extract_moduledoc_from_ast({:__block__, _, statements}) when is_list(statements) do
    Enum.find_value(statements, fn
      # Standard string
      {:@, _, [{:moduledoc, _, [doc]}]} when is_binary(doc) -> doc
      # Sourceror wraps strings in __block__
      {:@, _, [{:moduledoc, _, [{:__block__, _, [doc]}]}]} when is_binary(doc) -> doc
      # Sigil S
      {:@, _, [{:moduledoc, _, [{:sigil_S, _, [{:<<>>, _, [doc]}, []]}]}]} when is_binary(doc) -> doc
      # false (no doc)
      {:@, _, [{:moduledoc, _, [false]}]} -> nil
      {:@, _, [{:moduledoc, _, [{:__block__, _, [false]}]}]} -> nil
      _ -> nil
    end)
  end

  defp extract_moduledoc_from_ast({:@, _, [{:moduledoc, _, [doc]}]}) when is_binary(doc), do: doc
  defp extract_moduledoc_from_ast({:@, _, [{:moduledoc, _, [{:__block__, _, [doc]}]}]}) when is_binary(doc), do: doc
  defp extract_moduledoc_from_ast(_), do: nil

  @doc """
  Extract function definitions from AST using Macro.prewalk.
  """
  @spec extract_functions(ast()) :: [function_info()]
  def extract_functions(ast) do
    require Logger

    try do
      {_ast, functions} = Macro.prewalk(ast, [], fn node, acc ->
        case safe_extract_function_info(node) do
          {:ok, func_info} -> {node, [func_info | acc]}
          :skip -> {node, acc}
        end
      end)

      funcs = functions |> Enum.reverse() |> Enum.uniq_by(fn f -> {f.name, f.arity} end)
      Logger.info("extract_functions found #{length(funcs)} functions")
      funcs
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # Safe wrapper that never crashes
  defp safe_extract_function_info(node) do
    try do
      extract_function_info(node)
    rescue
      _ -> :skip
    catch
      _, _ -> :skip
    end
  end

  # Extract function info from various AST patterns

  # def/defp with when clause: def foo(x) when is_integer(x), do: ...
  defp extract_function_info({def_type, meta, [{:when, _, [{name, _, args} | _]} | _]})
       when def_type in [:def, :defp] and is_atom(name) do
    {:ok, build_function_info(name, args, def_type, meta)}
  end

  # Standard def/defp: def foo(x), do: ...
  defp extract_function_info({def_type, meta, [{name, _, args} | _]})
       when def_type in [:def, :defp] and is_atom(name) do
    {:ok, build_function_info(name, args, def_type, meta)}
  end

  # Not a function definition
  defp extract_function_info(_), do: :skip

  defp build_function_info(name, args, def_type, meta) do
    arity = if is_list(args), do: length(args), else: 0
    %{
      name: name,
      arity: arity,
      type: def_type,
      line: Keyword.get(meta, :line, 0)
    }
  end

  @doc """
  Extract imports, aliases, uses, and requires from AST.
  """
  @spec extract_imports(ast()) :: [import_info()]
  def extract_imports(ast) do
    try do
      {_ast, imports} = Macro.prewalk(ast, [], fn node, acc ->
        case safe_extract_import_info(node) do
          {:ok, import_info} -> {node, [import_info | acc]}
          {:ok_multi, entries} -> {node, Enum.reverse(entries) ++ acc}
          :skip -> {node, acc}
        end
      end)

      Enum.reverse(imports)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # Safe wrapper that never crashes
  defp safe_extract_import_info(node) do
    try do
      case extract_import_info(node) do
        {:ok_multi, entries} -> {:ok_multi, entries}
        other -> other
      end
    rescue
      _ -> :skip
    catch
      _, _ -> :skip
    end
  end

  # Extract import/alias/use/require info

  # Multi-module: alias Giulia.Core.{ProjectContext, PathMapper, PathSandbox}
  # Sourceror parses this as: {:alias, meta, [{{:., _, [base, :{}]}, _, children}]}
  # We expand it into multiple import entries
  defp extract_import_info({directive, meta, [{{:., _, [{:__aliases__, _, base_parts}, :{}]}, _, children}]})
       when directive in [:import, :alias, :use, :require] do
    base = base_parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)

    entries = Enum.map(children, fn
      {:__aliases__, _, parts} when is_list(parts) ->
        child = parts |> Enum.map(&to_string/1) |> Enum.join(".")
        %{type: directive, module: "#{base}.#{child}", line: line}
      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)

    {:ok_multi, entries}
  end

  # @behaviour Giulia.Tools.Registry — a hard dependency (implements callbacks)
  defp extract_import_info({:@, meta, [{:behaviour, _, [{:__aliases__, _, parts}]}]})
       when is_list(parts) do
    {:ok, %{
      type: :use,  # Treat @behaviour as :use for dependency tracking (hard edge)
      module: parts |> Enum.map(&to_string/1) |> Enum.join("."),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  # @behaviour with atom module (e.g. @behaviour :gen_server)
  defp extract_import_info({:@, meta, [{:behaviour, _, [module_atom]}]})
       when is_atom(module_atom) do
    {:ok, %{
      type: :use,
      module: Atom.to_string(module_atom),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  # Standard: import Foo.Bar
  defp extract_import_info({directive, meta, [{:__aliases__, _, parts} | _]})
       when directive in [:import, :alias, :use, :require] and is_list(parts) do
    {:ok, %{
      type: directive,
      module: parts |> Enum.map(&to_string/1) |> Enum.join("."),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  # Atom module: use :logger
  defp extract_import_info({directive, meta, [module_atom | _]})
       when directive in [:import, :alias, :use, :require] and is_atom(module_atom) do
    {:ok, %{
      type: directive,
      module: Atom.to_string(module_atom),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  # Not an import directive
  defp extract_import_info(_), do: :skip

  # ============================================================================
  # Type Extraction (@type, @typep, @opaque)
  # ============================================================================

  @doc """
  Extract type definitions from AST.
  """
  @spec extract_types(ast()) :: [type_info()]
  def extract_types(ast) do
    try do
      {_ast, types} = Macro.prewalk(ast, [], fn node, acc ->
        case extract_type_info(node) do
          {:ok, type_info} -> {node, [type_info | acc]}
          :skip -> {node, acc}
        end
      end)

      Enum.reverse(types)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # @type name :: definition
  defp extract_type_info({:@, meta, [{type_kind, _, [{:"::", _, [{name, _, args}, _definition]}]}]})
       when type_kind in [:type, :typep, :opaque] and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, %{
      name: name,
      arity: arity,
      visibility: type_kind,
      line: Keyword.get(meta, :line, 0),
      definition: "" # We'll get the string representation later if needed
    }}
  end

  # @type name (no args)
  defp extract_type_info({:@, meta, [{type_kind, _, [{:"::", _, [{name, _, nil}, _definition]}]}]})
       when type_kind in [:type, :typep, :opaque] and is_atom(name) do
    {:ok, %{
      name: name,
      arity: 0,
      visibility: type_kind,
      line: Keyword.get(meta, :line, 0),
      definition: ""
    }}
  end

  defp extract_type_info(_), do: :skip

  # ============================================================================
  # Spec Extraction (@spec)
  # ============================================================================

  @doc """
  Extract @spec definitions from AST.
  """
  @spec extract_specs(ast()) :: [spec_info()]
  def extract_specs(ast) do
    try do
      {_ast, specs} = Macro.prewalk(ast, [], fn node, acc ->
        case extract_spec_info(node) do
          {:ok, spec_info} -> {node, [spec_info | acc]}
          :skip -> {node, acc}
        end
      end)

      Enum.reverse(specs)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # @spec function_name(args) :: return_type
  defp extract_spec_info({:@, meta, [{:spec, _, [{:"::", _, [{name, _, args}, _return]} = spec_ast]}]})
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, %{
      function: name,
      arity: arity,
      spec: Macro.to_string(spec_ast),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  # @spec with when clause
  defp extract_spec_info({:@, meta, [{:spec, _, [{:when, _, [{:"::", _, [{name, _, args}, _return]} = spec_ast | when_clauses]}]}]})
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, %{
      function: name,
      arity: arity,
      spec: Macro.to_string({:when, [], [spec_ast | when_clauses]}),
      line: Keyword.get(meta, :line, 0)
    }}
  end

  defp extract_spec_info(_), do: :skip

  # ============================================================================
  # Callback Extraction (@callback)
  # ============================================================================

  @doc """
  Extract @callback definitions from AST.
  Tags each callback with `optional: true/false` based on `@optional_callbacks`.
  """
  @spec extract_callbacks(ast()) :: [callback_info()]
  def extract_callbacks(ast) do
    try do
      optional_set = extract_optional_callbacks(ast)

      {_ast, callbacks} = Macro.prewalk(ast, [], fn node, acc ->
        case extract_callback_info(node) do
          {:ok, callback_info} ->
            tagged = Map.put(callback_info, :optional,
              MapSet.member?(optional_set, {callback_info.function, callback_info.arity}))
            {node, [tagged | acc]}
          :skip -> {node, acc}
        end
      end)

      Enum.reverse(callbacks)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  @doc """
  Extract `@optional_callbacks` attribute from AST.
  Returns a MapSet of `{function_name, arity}` tuples.
  """
  @spec extract_optional_callbacks(ast()) :: MapSet.t({atom(), non_neg_integer()})
  def extract_optional_callbacks(ast) do
    try do
      {_ast, optionals} = Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # @optional_callbacks [func: arity, ...] — keyword list
          {:@, _, [{:optional_callbacks, _, [items]}]} when is_list(items) ->
            pairs = extract_optional_pairs(items)
            {node, pairs ++ acc}

          # Sourceror wraps the list: @optional_callbacks [{:__block__, _, [...]}]
          {:@, _, [{:optional_callbacks, _, [{:__block__, _, [items]}]}]} when is_list(items) ->
            pairs = extract_optional_pairs(items)
            {node, pairs ++ acc}

          _ ->
            {node, acc}
        end
      end)

      MapSet.new(optionals)
    rescue
      _ -> MapSet.new()
    catch
      _, _ -> MapSet.new()
    end
  end

  # Parse optional callback entries from various AST shapes
  defp extract_optional_pairs(items) when is_list(items) do
    Enum.flat_map(items, fn
      # Keyword: [func_name: arity] — standard AST
      {name, arity} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      # Sourceror wraps integer in __block__: {name, {:__block__, _, [arity]}}
      {name, {:__block__, _, [arity]}} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      # Sourceror wraps atom key: {{:__block__, _, [name]}, {:__block__, _, [arity]}}
      {{:__block__, _, [name]}, {:__block__, _, [arity]}} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      # Tuple form: {:func_name, arity}
      {:__block__, _, [{name, arity}]} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      _ ->
        []
    end)
  end

  defp extract_optional_pairs(_), do: []

  # @callback function_name(args) :: return_type
  defp extract_callback_info({:@, meta, [{:callback, _, [{:"::", _, [{name, _, args}, _return]}]}]})
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, %{
      function: name,
      arity: arity,
      spec: "",
      line: Keyword.get(meta, :line, 0)
    }}
  end

  defp extract_callback_info(_), do: :skip

  # ============================================================================
  # Struct Extraction (defstruct)
  # ============================================================================

  @doc """
  Extract defstruct definitions from AST.
  """
  @spec extract_structs(ast()) :: [struct_info()]
  def extract_structs(ast) do
    try do
      # We need to track current module context for struct extraction
      {_ast, {_module, structs}} = Macro.prewalk(ast, {nil, []}, fn node, {current_module, acc} ->
        case node do
          # Track module context
          {:defmodule, _, [{:__aliases__, _, parts} | _]} ->
            module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
            {node, {module_name, acc}}

          # defstruct with keyword list (standard AST)
          {:defstruct, meta, [fields]} when is_list(fields) ->
            field_names = extract_struct_fields(fields)
            struct_info = %{
              module: current_module || "Unknown",
              fields: field_names,
              line: Keyword.get(meta, :line, 0)
            }
            {node, {current_module, [struct_info | acc]}}

          # defstruct with Sourceror __block__ wrapper
          {:defstruct, meta, [{:__block__, _, [fields]}]} when is_list(fields) ->
            field_names = extract_struct_fields(fields)
            struct_info = %{
              module: current_module || "Unknown",
              fields: field_names,
              line: Keyword.get(meta, :line, 0)
            }
            {node, {current_module, [struct_info | acc]}}

          _ ->
            {node, {current_module, acc}}
        end
      end)

      Enum.reverse(structs)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      # Standard keyword: {key, default}
      {key, _default} when is_atom(key) -> key
      # Simple atom field
      key when is_atom(key) -> key
      # Sourceror wrapped atom: {:__block__, _, [atom]}
      {:__block__, _, [key]} when is_atom(key) -> key
      # Sourceror wrapped keyword: {{:__block__, _, [key]}, _default}
      {{:__block__, _, [key]}, _default} when is_atom(key) -> key
      _ -> :unknown
    end)
    |> Enum.filter(&(&1 != :unknown))
  end

  defp extract_struct_fields(_), do: []

  # ============================================================================
  # Doc Extraction (@doc, @moduledoc)
  # ============================================================================

  @doc """
  Extract @doc definitions from AST.
  Links docs to following function definitions.
  """
  @spec extract_docs(ast()) :: [doc_info()]
  def extract_docs(ast) do
    try do
      # First pass: collect all @doc positions and their content
      {_ast, doc_entries} = Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {:@, meta, [{:doc, _, [doc_content]}]} when is_binary(doc_content) ->
            entry = %{line: Keyword.get(meta, :line, 0), doc: doc_content}
            {node, [entry | acc]}

          {:@, meta, [{:doc, _, [{:sigil_S, _, [{:<<>>, _, [doc_content]}, []]}]}]} when is_binary(doc_content) ->
            entry = %{line: Keyword.get(meta, :line, 0), doc: doc_content}
            {node, [entry | acc]}

          # Handle heredoc style @doc """..."""
          {:@, meta, [{:doc, _, [{:__block__, _, [doc_content]}]}]} when is_binary(doc_content) ->
            entry = %{line: Keyword.get(meta, :line, 0), doc: doc_content}
            {node, [entry | acc]}

          _ ->
            {node, acc}
        end
      end)

      # Second pass: collect functions
      functions = extract_functions(ast)

      # Match docs to functions (doc should be immediately before function)
      doc_entries
      |> Enum.reverse()
      |> Enum.map(fn %{line: doc_line, doc: doc_content} ->
        # Find function that follows this doc (within 10 lines)
        matching_func = Enum.find(functions, fn func ->
          func.line > doc_line and func.line <= doc_line + 10
        end)

        case matching_func do
          nil -> nil
          func -> %{
            function: func.name,
            arity: func.arity,
            doc: doc_content,
            line: doc_line
          }
        end
      end)
      |> Enum.filter(&(&1 != nil))
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  @doc """
  Extract @moduledoc from a module.
  """
  @spec extract_moduledoc(ast()) :: String.t() | nil
  def extract_moduledoc(ast) do
    try do
      {_ast, moduledoc} = Macro.prewalk(ast, nil, fn node, acc ->
        case node do
          {:@, _, [{:moduledoc, _, [doc_content]}]} when is_binary(doc_content) ->
            {node, doc_content}

          # Sourceror wraps heredoc strings in {:__block__, _, [string]}
          {:@, _, [{:moduledoc, _, [{:__block__, _, [doc_content]}]}]} when is_binary(doc_content) ->
            {node, doc_content}

          {:@, _, [{:moduledoc, _, [{:sigil_S, _, [{:<<>>, _, [doc_content]}, []]}]}]} when is_binary(doc_content) ->
            {node, doc_content}

          {:@, _, [{:moduledoc, _, [false]}]} ->
            {node, false}

          # Sourceror wraps false in {:__block__, _, [false]}
          {:@, _, [{:moduledoc, _, [{:__block__, _, [false]}]}]} ->
            {node, false}

          _ ->
            {node, acc}
        end
      end)

      case moduledoc do
        false -> nil
        doc -> doc
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  @doc """
  Count source lines.
  """
  @spec count_lines(String.t()) :: non_neg_integer()
  def count_lines(source) when is_binary(source) do
    source |> String.split("\n") |> length()
  end

  def count_lines(_), do: 0

  @doc """
  Estimate code complexity based on control flow.
  """
  @spec estimate_complexity(ast()) :: non_neg_integer()
  def estimate_complexity(ast) do
    try do
      {_ast, complexity} = Macro.prewalk(ast, 0, fn node, acc ->
        case node do
          {:case, _, _} -> {node, acc + 1}
          {:cond, _, _} -> {node, acc + 1}
          {:if, _, _} -> {node, acc + 1}
          {:unless, _, _} -> {node, acc + 1}
          {:with, _, _} -> {node, acc + 2}
          {:try, _, _} -> {node, acc + 2}
          {:receive, _, _} -> {node, acc + 2}
          {:def, _, _} -> {node, acc + 1}
          {:defp, _, _} -> {node, acc + 1}
          _ -> {node, acc}
        end
      end)

      complexity
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  # ============================================================================
  # Code Patching (Write Back)
  # ============================================================================

  @doc """
  Patch a specific function in the source code.
  Returns the modified source with formatting preserved.
  """
  @spec patch_function(String.t(), atom(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def patch_function(source, function_name, arity, new_body) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, new_ast} <- Sourceror.parse_string(new_body) do
      patched =
        Sourceror.postwalk(ast, fn
          {def_type, _meta, [{^function_name, _fn_meta, args} | _]} = node
          when def_type in [:def, :defp] ->
            if length(args || []) == arity do
              # Replace with new function body
              new_ast
            else
              node
            end

          node ->
            node
        end)

      {:ok, Macro.to_string(patched)}
    end
  end

  @doc """
  Insert a new function into a module.
  """
  @spec insert_function(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def insert_function(source, module_name, function_source) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, func_ast} <- Sourceror.parse_string(function_source) do
      module_parts = String.split(module_name, ".") |> Enum.map(&String.to_atom/1)

      patched =
        Sourceror.postwalk(ast, fn
          {:defmodule, meta, [{:__aliases__, alias_meta, ^module_parts}, body_block]} ->
            # Insert function into module body
            [do: {:__block__, block_meta, body}] = body_block
            new_body = body ++ [func_ast]
            {:defmodule, meta, [{:__aliases__, alias_meta, module_parts}, [do: {:__block__, block_meta, new_body}]]}

          node ->
            node
        end)

      {:ok, Macro.to_string(patched)}
    end
  end

  @doc """
  Get the source range for a specific function.
  """
  @spec get_function_range(ast(), atom(), non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :not_found
  def get_function_range(ast, function_name, arity) do
    result =
      ast
      |> Sourceror.prewalk(nil, fn
        {def_type, meta, [{^function_name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            start_line = Keyword.get(meta, :line, 0)
            end_line = Keyword.get(meta, :end_of_expression, []) |> Keyword.get(:line, start_line)
            {node, {start_line, end_line}}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    case result do
      nil -> :not_found
      range -> {:ok, range}
    end
  end

  # ============================================================================
  # Summary for LLM Context
  # ============================================================================

  @doc """
  Generate a compact summary for LLM context.
  """
  @spec summarize(file_info()) :: String.t()
  def summarize(info) do
    modules = Enum.map_join(info.modules, ", ", & &1.name)
    functions = Enum.map_join(info.functions, ", ", &"#{&1.name}/#{&1.arity}")
    imports = info.imports |> Enum.map(& &1.module) |> Enum.uniq() |> Enum.join(", ")

    """
    Modules: #{modules}
    Functions: #{functions}
    Imports: #{imports}
    Lines: #{info.line_count}
    Complexity: #{info.complexity}
    """
  end

  @doc """
  Generate a detailed summary with function signatures.
  """
  @spec detailed_summary(file_info()) :: String.t()
  def detailed_summary(info) do
    module_section =
      info.modules
      |> Enum.map_join("\n", fn m -> "  - #{m.name} (line #{m.line})" end)

    function_section =
      info.functions
      |> Enum.map_join("\n", fn f ->
        visibility = if f.type == :def, do: "public", else: "private"
        "  - #{f.name}/#{f.arity} [#{visibility}] (line #{f.line})"
      end)

    """
    === File Analysis ===
    Lines: #{info.line_count} | Complexity: #{info.complexity}

    Modules:
    #{module_section}

    Functions:
    #{function_section}
    """
  end

  # ============================================================================
  # Context Slicing (For Small Models)
  # ============================================================================

  @doc """
  Extract only a specific function from source code.
  Returns the function source with minimal context.

  Use this for small models (3B) - 20 lines of context beats 200.
  """
  @spec slice_function(String.t(), atom(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def slice_function(source, function_name, arity) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      # Use Macro.prewalk for consistency with extract_functions
      {_ast, result} = Macro.prewalk(ast, nil, fn
        {def_type, _meta, [{name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] and is_atom(name) ->
          # Compare function names (both should be atoms)
          name_matches = name == function_name or to_string(name) == to_string(function_name)
          arity_matches = length(args || []) == arity

          if name_matches and arity_matches do
            # Use Macro.to_string - works in production releases (no Mix dependency)
            {node, Macro.to_string(node)}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

      case result do
        nil -> {:error, :function_not_found}
        func_source -> {:ok, func_source}
      end
    end
  end

  @doc """
  Extract a function and its direct dependencies (called functions in same module).
  Returns a focused slice of code for the LLM.
  """
  @spec slice_function_with_deps(String.t(), atom(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def slice_function_with_deps(source, function_name, arity) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, target_func} <- find_function_ast(ast, function_name, arity) do
      # Find functions called within the target
      called_functions = extract_called_functions(target_func)

      # Extract all relevant functions
      slices =
        [{function_name, arity} | called_functions]
        |> Enum.uniq()
        |> Enum.map(fn {name, ar} -> find_function_ast(ast, name, ar) end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, func_ast} -> Macro.to_string(func_ast) end)

      {:ok, Enum.join(slices, "\n\n")}
    end
  end

  @doc """
  Slice source to only include lines around an error location.
  Useful for sending error context to small models.
  """
  @spec slice_around_line(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def slice_around_line(source, line, context_lines \\ 10)

  def slice_around_line(source, line, context_lines) when is_binary(source) do
    safe_line = if is_integer(line), do: line, else: 1
    safe_context = if is_integer(context_lines), do: context_lines, else: 10

    lines = String.split(source, "\n")
    total_lines = length(lines)

    start_line = max(0, safe_line - safe_context - 1)
    end_line = min(total_lines - 1, safe_line + safe_context - 1)

    lines
    |> Enum.slice(start_line..end_line)
    |> Enum.with_index(start_line + 1)
    |> Enum.map_join("\n", fn {content, num} ->
      marker = if num == safe_line, do: ">>> ", else: "    "
      "#{marker}#{num}: #{content}"
    end)
  end

  def slice_around_line(_, _, _), do: ""

  @doc """
  Create a minimal context for a specific error.
  Combines function slice with error location.
  """
  @spec slice_for_error(String.t(), non_neg_integer(), String.t()) :: String.t()
  def slice_for_error(source, error_line, error_message) do
    with {:ok, ast, _} <- parse(source) do
      # Find which function contains the error
      func = find_function_at_line(ast, error_line)

      case func do
        nil ->
          # No function found, just show lines around error
          """
          Error: #{error_message}

          Context:
          #{slice_around_line(source, error_line)}
          """

        {name, arity, func_source} ->
          """
          Error in #{name}/#{arity}: #{error_message}

          Function:
          #{func_source}
          """
      end
    else
      _ ->
        """
        Error: #{error_message}

        Context:
        #{slice_around_line(source, error_line)}
        """
    end
  end

  # Private helpers for slicing

  defp find_function_ast(ast, function_name, arity) do
    result =
      ast
      |> Sourceror.prewalk(nil, fn
        {def_type, _meta, [{^function_name, _, args} | _]} = node, nil
        when def_type in [:def, :defp] ->
          if length(args || []) == arity do
            {node, node}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    case result do
      nil -> {:error, :not_found}
      func -> {:ok, func}
    end
  end

  defp find_function_at_line(ast, target_line) do
    ast
    |> Sourceror.prewalk(nil, fn
      {def_type, meta, [{name, _, args} | _]} = node, nil
      when def_type in [:def, :defp] ->
        start_line = Keyword.get(meta, :line, 0)
        end_line = get_end_line(meta, start_line)
        arity = length(args || [])

        if target_line >= start_line and target_line <= end_line do
          {node, {name, arity, Macro.to_string(node)}}
        else
          {node, nil}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # Senior approach: Pattern-match on reality, not math on assumptions
  # The Architect's "Metadata-First" pattern
  defp get_line_range(meta) when is_list(meta) do
    start_line = Keyword.get(meta, :line, 1)
    # Don't assume +10; default to start_line if end is missing
    end_line = case Keyword.get(meta, :end_of_expression) do
      nil -> start_line
      end_meta when is_list(end_meta) -> Keyword.get(end_meta, :line, start_line)
      _ -> start_line
    end
    {start_line, end_line}
  end

  defp get_line_range(_), do: {1, 1}

  # Legacy helper for compatibility
  defp get_end_line(meta, default) when is_list(meta) and is_integer(default) do
    {_start, end_line} = get_line_range(meta)
    if end_line > 0, do: end_line, else: default
  end

  defp get_end_line(_, default) when is_integer(default), do: default
  defp get_end_line(_, _), do: 1

  defp extract_called_functions(func_ast) do
    func_ast
    |> Sourceror.prewalk([], fn
      {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
        # Skip common non-function atoms
        if name not in [:def, :defp, :do, :end, :if, :case, :cond, :fn, :&, :|>] do
          {node, [{name, length(args)} | acc]}
        else
          {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
  end
end
