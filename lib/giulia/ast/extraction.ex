defmodule Giulia.AST.Extraction do
  @moduledoc """
  AST metadata extraction — modules, functions, imports, types, specs,
  callbacks, structs, and docs.

  All functions take a parsed AST (Macro.t()) and return lists of
  structured metadata maps. Uses Macro.prewalk for traversal.
  """

  # ============================================================================
  # Module Extraction
  # ============================================================================

  @doc """
  Extract module definitions from AST using Macro.prewalk.
  """
  @spec extract_modules(Macro.t()) :: [Giulia.AST.Processor.module_info()]
  def extract_modules(ast) do
    require Logger

    try do
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
      name: parts |> Enum.map(&safe_part_to_string/1) |> Enum.join("."),
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
      # @moduledoc false — intentionally undocumented (preserve as false, not nil)
      {:@, _, [{:moduledoc, _, [false]}]} -> false
      {:@, _, [{:moduledoc, _, [{:__block__, _, [false]}]}]} -> false
      _ -> nil
    end)
  end

  defp extract_moduledoc_from_ast({:@, _, [{:moduledoc, _, [doc]}]}) when is_binary(doc), do: doc
  defp extract_moduledoc_from_ast({:@, _, [{:moduledoc, _, [{:__block__, _, [doc]}]}]}) when is_binary(doc), do: doc
  defp extract_moduledoc_from_ast(_), do: nil

  # ============================================================================
  # Function Extraction
  # ============================================================================

  @doc """
  Extract function definitions from AST using Macro.prewalk.
  """
  @spec extract_functions(Macro.t()) :: [Giulia.AST.Processor.function_info()]
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

  @def_types [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp]

  # def/defp/defmacro/defguard with when clause: def foo(x) when is_integer(x), do: ...
  defp extract_function_info({def_type, meta, [{:when, _, [{name, _, args} | _]} | _]})
       when def_type in @def_types and is_atom(name) do
    {:ok, build_function_info(name, args, def_type, meta)}
  end

  # Standard def/defp/defmacro/defdelegate/defguard: def foo(x), do: ...
  defp extract_function_info({def_type, meta, [{name, _, args} | _]})
       when def_type in @def_types and is_atom(name) do
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

  # ============================================================================
  # Import / Alias / Use / Require Extraction
  # ============================================================================

  @doc """
  Extract imports, aliases, uses, and requires from AST.
  """
  @spec extract_imports(Macro.t()) :: [Giulia.AST.Processor.import_info()]
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

  # Multi-module: alias Giulia.Core.{ProjectContext, PathMapper, PathSandbox}
  defp extract_import_info({directive, meta, [{{:., _, [{:__aliases__, _, base_parts}, :{}]}, _, children}]})
       when directive in [:import, :alias, :use, :require] do
    base = base_parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)

    entries = Enum.reject(Enum.map(children, fn
      {:__aliases__, _, parts} when is_list(parts) ->
        child = parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")
        %{type: directive, module: "#{base}.#{child}", line: line}
      _ ->
        nil
    end), &is_nil/1)

    {:ok_multi, entries}
  end

  # @behaviour Giulia.Tools.Registry — a hard dependency
  defp extract_import_info({:@, meta, [{:behaviour, _, [{:__aliases__, _, parts}]}]})
       when is_list(parts) do
    {:ok, %{
      type: :use,
      module: parts |> Enum.map(&safe_part_to_string/1) |> Enum.join("."),
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
      module: parts |> Enum.map(&safe_part_to_string/1) |> Enum.join("."),
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
  @spec extract_types(Macro.t()) :: [Giulia.AST.Processor.type_info()]
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
      definition: ""
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
  @spec extract_specs(Macro.t()) :: [Giulia.AST.Processor.spec_info()]
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
  @spec extract_callbacks(Macro.t()) :: [Giulia.AST.Processor.callback_info()]
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
  @spec extract_optional_callbacks(Macro.t()) :: MapSet.t({atom(), non_neg_integer()})
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
  @spec extract_structs(Macro.t()) :: [Giulia.AST.Processor.struct_info()]
  def extract_structs(ast) do
    try do
      # We need to track current module context for struct extraction
      {_ast, {_module, structs}} = Macro.prewalk(ast, {nil, []}, fn node, {current_module, acc} ->
        case node do
          # Track module context
          {:defmodule, _, [{:__aliases__, _, parts} | _]} ->
            module_name = parts |> Enum.map(&safe_part_to_string/1) |> Enum.join(".")
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
    Enum.filter(Enum.map(fields, fn
      # Standard keyword: {key, default}
      {key, _default} when is_atom(key) -> key
      # Simple atom field
      key when is_atom(key) -> key
      # Sourceror wrapped atom: {:__block__, _, [atom]}
      {:__block__, _, [key]} when is_atom(key) -> key
      # Sourceror wrapped keyword: {{:__block__, _, [key]}, _default}
      {{:__block__, _, [key]}, _default} when is_atom(key) -> key
      _ -> :unknown
    end), &(&1 != :unknown))
  end

  defp extract_struct_fields(_), do: []

  # ============================================================================
  # Doc Extraction (@doc, @moduledoc)
  # ============================================================================

  @doc """
  Extract @doc definitions from AST.
  Links docs to following function definitions.
  """
  @spec extract_docs(Macro.t()) :: [Giulia.AST.Processor.doc_info()]
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
  @spec extract_moduledoc(Macro.t()) :: String.t() | false | nil
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

      moduledoc
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Safely convert AST alias parts to strings.
  # Handles {:__MODULE__, meta, nil} and other compile-time macros.
  defp safe_part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_part_to_string({:__ENV__, _, _}), do: "__ENV__"
  defp safe_part_to_string({:__DIR__, _, _}), do: "__DIR__"
  defp safe_part_to_string({:__CALLER__, _, _}), do: "__CALLER__"
  defp safe_part_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_part_to_string(other), do: inspect(other)
end
