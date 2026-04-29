defmodule Giulia.Context.Store.Query do
  @moduledoc """
  Query layer over ETS-backed AST data.

  All read-only queries over indexed AST entries: module lookups,
  function searches, type/spec/callback/struct/doc enumeration.

  Extracted from `Context.Store` (Build 111).
  """

  # Types inlined to avoid circular dependency (Store delegates to Query)
  @type project_path :: String.t()
  @type file_path :: String.t()
  @type module_name :: String.t()
  @type module_entry :: %{name: String.t(), file: String.t(), line: non_neg_integer()}
  @type function_entry :: %{
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          type: atom(),
          file: String.t(),
          line: non_neg_integer(),
          complexity: non_neg_integer()
        }

  # ETS table name — same as Store's @table
  @table Giulia.Context.Store

  # Direct ETS read — avoids routing through Store (cycle breaker)
  defp all_asts(project_path) do
    :ets.match_object(@table, {{:ast, project_path, :_}, :_})
    |> Enum.map(fn {{:ast, _proj, path}, data} -> {path, data} end)
    |> Map.new()
  end

  # ============================================================================
  # Module Queries
  # ============================================================================

  @doc """
  List all modules in the indexed project.
  Returns a list of module names with their file paths.
  """
  @spec list_modules(project_path()) :: [module_entry()]
  def list_modules(project_path) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      modules = ast_data[:modules] || []

      Enum.map(modules, fn mod ->
        %{
          name: mod.name,
          file: path,
          line: mod.line
        }
      end)
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Find a specific module by name within a project.
  Returns {:ok, %{file: path, ast_data: data}} or :not_found.
  """
  @spec find_module(project_path(), module_name()) ::
          {:ok, %{file: file_path(), ast_data: map()}} | :not_found
  def find_module(project_path, module_name) do
    Enum.find_value(all_asts(project_path), :not_found, fn {path, ast_data} ->
      modules = ast_data[:modules] || []

      if Enum.any?(modules, &(&1.name == module_name)) do
        {:ok, %{file: path, ast_data: ast_data}}
      else
        nil
      end
    end)
  end

  @doc """
  Find the primary module defined in a file path within a project.
  Returns {:ok, %{name: module_name}} or :not_found.
  """
  @spec find_module_by_file(project_path(), file_path()) ::
          {:ok, %{name: module_name()}} | :not_found
  def find_module_by_file(project_path, file_path) do
    # Normalize path separators for matching
    normalized = String.replace(file_path, "\\", "/")

    Enum.find_value(all_asts(project_path), :not_found, fn {path, ast_data} ->
      path_normalized = String.replace(path, "\\", "/")

      if String.ends_with?(path_normalized, normalized) or
           String.ends_with?(normalized, path_normalized) do
        modules = ast_data[:modules] || []

        case modules do
          [first | _] -> {:ok, %{name: first.name}}
          _ -> nil
        end
      else
        nil
      end
    end)
  end

  # ============================================================================
  # Function Queries
  # ============================================================================

  @doc """
  List all functions in the indexed project, optionally filtered by module.

  ## Examples

      list_functions(project_path, nil)                          # All functions
      list_functions(project_path, "Giulia.StructuredOutput")    # Single module
  """
  @spec list_functions(project_path(), module_name() | nil) :: [function_entry()]
  def list_functions(project_path, module_filter) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      functions = ast_data[:functions] || []

      # Fallback for pre-traversal-refactor cached entries where
      # function_info had no :module field. Uses the file's first
      # declared module — matches the old "first module wins"
      # attribution for any legacy data that slipped through.
      fallback_module =
        case ast_data[:modules] do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

      functions
      |> Enum.map(fn func ->
        %{
          module: Map.get(func, :module) || fallback_module,
          name: func.name,
          arity: func.arity,
          type: func.type,
          file: path,
          line: func.line,
          complexity: Map.get(func, :complexity, 0)
        }
      end)
      |> Enum.filter(fn entry ->
        module_filter == nil or entry.module == module_filter
      end)
    end)
    |> Enum.sort_by(&{&1.module, &1.name, &1.arity})
  end

  @doc """
  Functions ranked by cognitive complexity descending. Replaces the
  inline `list_functions |> filter |> sort |> take` chain that
  previously duplicated between `Giulia.Daemon.Routers.Index` and the
  MCP `index_complexity` dispatch.

  Options:
    * `:module` — filter to a single module (default: all modules)
    * `:min` — minimum complexity threshold (default: 0)
    * `:limit` — maximum results returned (default: 50)
  """
  @spec functions_by_complexity(project_path(), keyword()) :: %{
          functions: [function_entry()],
          count: non_neg_integer(),
          module: module_name() | nil,
          min_complexity: non_neg_integer()
        }
  def functions_by_complexity(project_path, opts \\ []) do
    module_filter = Keyword.get(opts, :module)
    min_complexity = Keyword.get(opts, :min, 0)
    result_limit = Keyword.get(opts, :limit, 50)

    functions =
      project_path
      |> list_functions(module_filter)
      |> Enum.filter(fn f -> f.complexity >= min_complexity end)
      |> Enum.sort_by(& &1.complexity, :desc)
      |> Enum.take(result_limit)

    %{
      functions: functions,
      count: length(functions),
      module: module_filter,
      min_complexity: min_complexity
    }
  end

  @doc """
  Find a specific function by name (optionally with arity) within a project.
  Returns a list of matches across all modules.
  """
  @spec find_function(project_path(), atom() | String.t(), non_neg_integer() | nil) :: [
          function_entry()
        ]
  def find_function(project_path, function_name, arity) do
    Enum.filter(list_functions(project_path, nil), fn func ->
      name_match = to_string(func.name) == to_string(function_name)
      arity_match = arity == nil or func.arity == arity
      name_match and arity_match
    end)
  end

  # ============================================================================
  # Type / Spec Queries
  # ============================================================================

  @doc """
  List all types defined in the project.
  """
  @spec list_types(project_path(), module_name() | nil) :: [map()]
  def list_types(project_path, module_filter) do
    Enum.flat_map(all_asts(project_path), fn {path, ast_data} ->
      types = ast_data[:types] || []
      modules = ast_data[:modules] || []

      module_name =
        case modules do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

      if module_filter == nil or module_name == module_filter do
        Enum.map(types, fn type ->
          Map.merge(type, %{module: module_name, file: path})
        end)
      else
        []
      end
    end)
  end

  @doc """
  List all specs defined in the project.
  """
  @spec list_specs(project_path(), module_name() | nil) :: [map()]
  def list_specs(project_path, module_filter) do
    Enum.flat_map(all_asts(project_path), fn {path, ast_data} ->
      specs = ast_data[:specs] || []
      modules = ast_data[:modules] || []

      module_name =
        case modules do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

      if module_filter == nil or module_name == module_filter do
        Enum.map(specs, fn spec ->
          Map.merge(spec, %{module: module_name, file: path})
        end)
      else
        []
      end
    end)
  end

  @doc """
  Get spec for a specific function.
  """
  @spec get_spec(project_path(), module_name(), atom() | String.t(), non_neg_integer()) ::
          map() | nil
  def get_spec(project_path, module_name, function_name, arity) do
    Enum.find(list_specs(project_path, module_name), fn spec ->
      to_string(spec.function) == to_string(function_name) and spec.arity == arity
    end)
  end

  # ============================================================================
  # Callback Queries
  # ============================================================================

  @doc """
  List all callbacks (behaviour definitions) in the project.
  """
  @spec list_callbacks(project_path(), module_name() | nil) :: [map()]
  def list_callbacks(project_path, module_filter) do
    Enum.flat_map(all_asts(project_path), fn {path, ast_data} ->
      callbacks = ast_data[:callbacks] || []
      modules = ast_data[:modules] || []

      module_name =
        case modules do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

      if module_filter == nil or module_name == module_filter do
        Enum.map(callbacks, fn cb ->
          Map.merge(cb, %{module: module_name, file: path})
        end)
      else
        []
      end
    end)
  end

  @doc """
  List optional callbacks (where optional == true) in the project.
  """
  @spec list_optional_callbacks(project_path(), module_name() | nil) :: [map()]
  def list_optional_callbacks(project_path, module_filter) do
    Enum.filter(list_callbacks(project_path, module_filter), fn cb ->
      Map.get(cb, :optional, false) == true
    end)
  end

  # ============================================================================
  # Struct Queries
  # ============================================================================

  @doc """
  List all structs defined in the project.
  """
  @spec list_structs(project_path()) :: [map()]
  def list_structs(project_path) do
    Enum.flat_map(all_asts(project_path), fn {path, ast_data} ->
      structs = ast_data[:structs] || []

      Enum.map(structs, fn struct ->
        Map.put(struct, :file, path)
      end)
    end)
  end

  @doc """
  Get struct fields for a specific module.
  """
  @spec get_struct(project_path(), module_name()) :: map() | nil
  def get_struct(project_path, module_name) do
    Enum.find(list_structs(project_path), &(&1.module == module_name))
  end

  # ============================================================================
  # Doc Queries
  # ============================================================================

  @doc """
  List all @doc entries in the project.
  """
  @spec list_docs(project_path(), module_name() | nil) :: [map()]
  def list_docs(project_path, module_filter) do
    Enum.flat_map(all_asts(project_path), fn {path, ast_data} ->
      docs = ast_data[:docs] || []
      modules = ast_data[:modules] || []

      module_name =
        case modules do
          [%{name: name} | _] -> name
          _ -> "Unknown"
        end

      if module_filter == nil or module_name == module_filter do
        Enum.map(docs, fn doc ->
          Map.merge(doc, %{module: module_name, file: path})
        end)
      else
        []
      end
    end)
  end

  @doc """
  Get @doc for a specific function.
  """
  @spec get_function_doc(project_path(), module_name(), atom() | String.t(), non_neg_integer()) ::
          map() | nil
  def get_function_doc(project_path, module_name, function_name, arity) do
    Enum.find(list_docs(project_path, module_name), fn doc ->
      to_string(doc.function) == to_string(function_name) and doc.arity == arity
    end)
  end

  @doc """
  Get @moduledoc for a specific module.
  """
  @spec get_moduledoc(project_path(), module_name()) :: {:ok, String.t()} | :not_found
  def get_moduledoc(project_path, module_name) do
    case find_module(project_path, module_name) do
      {:ok, %{ast_data: ast_data}} ->
        modules = ast_data[:modules] || []

        case Enum.find(modules, &(&1.name == module_name)) do
          %{moduledoc: doc} when is_binary(doc) -> {:ok, doc}
          _ -> :not_found
        end

      :not_found ->
        :not_found
    end
  end
end
