defmodule Giulia.Context.Store do
  @moduledoc """
  ETS-backed store for project state.

  Holds the codebase map, AST metadata, and agent context.
  Survives terminal closure as long as the BEAM node runs.

  All AST data is namespaced by project_path to support multi-project isolation.
  ETS keys: {:ast, project_path, file_path}
  """
  use GenServer

  @table __MODULE__

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Store a file's AST metadata, scoped to a project.
  """
  def put_ast(project_path, path, ast_data) do
    :ets.insert(@table, {{:ast, project_path, path}, ast_data})
    :ok
  end

  @doc """
  Get a file's AST metadata, scoped to a project.
  """
  def get_ast(project_path, path) do
    case :ets.lookup(@table, {:ast, project_path, path}) do
      [{{:ast, ^project_path, ^path}, data}] -> {:ok, data}
      [] -> :error
    end
  end

  @doc """
  Get all indexed files with their AST metadata for a project.
  """
  def all_asts(project_path) do
    :ets.match_object(@table, {{:ast, project_path, :_}, :_})
    |> Enum.map(fn {{:ast, _proj, path}, data} -> {path, data} end)
    |> Map.new()
  end

  @doc """
  Store arbitrary key-value data.
  """
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  @doc """
  Get arbitrary key-value data.
  """
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Delete a key.
  """
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Clear all AST data for a specific project (for re-indexing).
  """
  def clear_asts(project_path) do
    :ets.match_delete(@table, {{:ast, project_path, :_}, :_})
    :ok
  end

  @doc """
  Get stats about the store for a specific project.
  """
  def stats(project_path) do
    ast_count =
      :ets.match_object(@table, {{:ast, project_path, :_}, :_})
      |> length()

    %{
      ast_files: ast_count,
      total_entries: :ets.info(@table, :size)
    }
  end

  @doc """
  Debug function to inspect what's actually in ETS for a project.
  """
  def debug_inspect(project_path) do
    require Logger

    all = all_asts(project_path)
    Logger.info("=== ETS DEBUG ===")
    Logger.info("Total AST entries: #{map_size(all)}")

    # Sample the first entry to see structure
    case Enum.take(all, 1) do
      [{path, ast_data}] ->
        Logger.info("Sample file: #{path}")
        Logger.info("AST data keys: #{inspect(Map.keys(ast_data))}")
        Logger.info("Modules raw: #{inspect(ast_data[:modules])}")
        Logger.info("Functions count: #{length(ast_data[:functions] || [])}")

      [] ->
        Logger.info("NO DATA IN ETS!")
    end

    # Count total modules across all files
    total_modules = Enum.reduce(all, 0, fn {_path, data}, acc ->
      acc + length(data[:modules] || [])
    end)

    Logger.info("Total modules across all files: #{total_modules}")
    Logger.info("=== END DEBUG ===")

    %{
      files: map_size(all),
      total_modules: total_modules,
      sample: Enum.take(all, 1)
    }
  end

  # ============================================================================
  # Query Interface - The "Knowledge" Layer
  # ============================================================================

  @doc """
  List all modules in the indexed project.
  Returns a list of module names with their file paths.
  """
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
  List all functions in the indexed project, optionally filtered by module.

  ## Examples

      list_functions(project_path)                           # All functions
      list_functions(project_path, "Giulia.StructuredOutput")  # Single module
      list_functions(project_path, nil)                        # Same as no filter
  """
  def list_functions(project_path, module_filter \\ nil) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      functions = ast_data[:functions] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

      # Filter by module if specified
      if module_filter == nil or module_name == module_filter do
        Enum.map(functions, fn func ->
          %{
            module: module_name,
            name: func.name,
            arity: func.arity,
            type: func.type,
            file: path,
            line: func.line
          }
        end)
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.module, &1.name, &1.arity})
  end

  @doc """
  Find a specific module by name within a project.
  Returns {:ok, %{file: path, ast_data: data}} or :not_found.
  """
  def find_module(project_path, module_name) do
    all_asts(project_path)
    |> Enum.find_value(:not_found, fn {path, ast_data} ->
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
  def find_module_by_file(project_path, file_path) do
    # Normalize path separators for matching
    normalized = String.replace(file_path, "\\", "/")

    all_asts(project_path)
    |> Enum.find_value(:not_found, fn {path, ast_data} ->
      path_normalized = String.replace(path, "\\", "/")
      if String.ends_with?(path_normalized, normalized) or String.ends_with?(normalized, path_normalized) do
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

  @doc """
  Find a specific function by name (optionally with arity) within a project.
  Returns a list of matches across all modules.
  """
  def find_function(project_path, function_name, arity \\ nil) do
    list_functions(project_path)
    |> Enum.filter(fn func ->
      name_match = to_string(func.name) == to_string(function_name)
      arity_match = arity == nil or func.arity == arity
      name_match and arity_match
    end)
  end

  @doc """
  List all types defined in the project.
  """
  def list_types(project_path, module_filter \\ nil) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      types = ast_data[:types] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

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
  def list_specs(project_path, module_filter \\ nil) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      specs = ast_data[:specs] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

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
  def get_spec(project_path, module_name, function_name, arity) do
    list_specs(project_path, module_name)
    |> Enum.find(fn spec ->
      to_string(spec.function) == to_string(function_name) and spec.arity == arity
    end)
  end

  @doc """
  List all callbacks (behaviour definitions) in the project.
  """
  def list_callbacks(project_path, module_filter \\ nil) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      callbacks = ast_data[:callbacks] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

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
  List all structs defined in the project.
  """
  def list_structs(project_path) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      structs = ast_data[:structs] || []
      Enum.map(structs, fn struct ->
        Map.put(struct, :file, path)
      end)
    end)
  end

  @doc """
  Get struct fields for a specific module.
  """
  def get_struct(project_path, module_name) do
    list_structs(project_path)
    |> Enum.find(&(&1.module == module_name))
  end

  @doc """
  List all @doc entries in the project.
  """
  def list_docs(project_path, module_filter \\ nil) do
    all_asts(project_path)
    |> Enum.flat_map(fn {path, ast_data} ->
      docs = ast_data[:docs] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

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
  def get_function_doc(project_path, module_name, function_name, arity) do
    list_docs(project_path, module_name)
    |> Enum.find(fn doc ->
      to_string(doc.function) == to_string(function_name) and doc.arity == arity
    end)
  end

  @doc """
  Get @moduledoc for a specific module.
  """
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

  @doc """
  Generate a compact project summary for LLM context injection.
  """
  def project_summary(project_path) do
    modules = list_modules(project_path)
    functions = list_functions(project_path)
    types = list_types(project_path)
    specs = list_specs(project_path)
    structs = list_structs(project_path)
    callbacks = list_callbacks(project_path)
    stats = stats(project_path)

    public_functions =
      functions
      |> Enum.filter(&(&1.type == :def))
      |> Enum.group_by(& &1.module)

    module_summaries =
      modules
      |> Enum.map(fn mod ->
        funcs = Map.get(public_functions, mod.name, [])
        func_list = Enum.map_join(funcs, ", ", &"#{&1.name}/#{&1.arity}")
        "  - #{mod.name}: #{func_list}"
      end)
      |> Enum.join("\n")

    """
    === PROJECT INDEX ===
    Files: #{stats.ast_files}
    Modules: #{length(modules)}
    Functions: #{length(functions)}
    Types: #{length(types)}
    Specs: #{length(specs)}
    Structs: #{length(structs)}
    Callbacks: #{length(callbacks)}

    Modules:
    #{module_summaries}
    """
  end

  @doc """
  Generate a detailed summary with types and structs for a specific module.
  """
  def module_details(project_path, module_name) do
    case find_module(project_path, module_name) do
      {:ok, %{file: file, ast_data: ast_data}} ->
        modules = ast_data[:modules] || []
        mod = Enum.find(modules, &(&1.name == module_name))

        functions = list_functions(project_path, module_name)
        types = list_types(project_path, module_name)
        specs = list_specs(project_path, module_name)
        callbacks = list_callbacks(project_path, module_name)
        struct_info = get_struct(project_path, module_name)

        public_funcs = Enum.filter(functions, &(&1.type == :def))
        private_funcs = Enum.filter(functions, &(&1.type == :defp))

        moduledoc_section = case mod[:moduledoc] do
          nil -> ""
          doc -> "\nModuledoc:\n  #{String.slice(doc, 0, 200)}#{if String.length(doc) > 200, do: "...", else: ""}\n"
        end

        struct_section = case struct_info do
          nil -> ""
          %{fields: fields} -> "\nStruct fields: #{Enum.join(fields, ", ")}\n"
        end

        types_section = if types != [] do
          type_list = Enum.map_join(types, ", ", &"#{&1.name}/#{&1.arity}")
          "\nTypes: #{type_list}\n"
        else
          ""
        end

        callbacks_section = if callbacks != [] do
          cb_list = Enum.map_join(callbacks, ", ", &"#{&1.function}/#{&1.arity}")
          "\nCallbacks: #{cb_list}\n"
        else
          ""
        end

        """
        === #{module_name} ===
        File: #{file}
        #{moduledoc_section}#{struct_section}#{types_section}#{callbacks_section}
        Public functions (#{length(public_funcs)}):
          #{Enum.map_join(public_funcs, "\n  ", &"#{&1.name}/#{&1.arity}")}

        Private functions (#{length(private_funcs)}):
          #{Enum.map_join(private_funcs, "\n  ", &"#{&1.name}/#{&1.arity}")}

        Specs defined: #{length(specs)}
        """

      :not_found ->
        "Module '#{module_name}' not found in index."
    end
  end

  # Server Callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
