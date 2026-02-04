defmodule Giulia.Context.Store do
  @moduledoc """
  ETS-backed store for project state.

  Holds the codebase map, AST metadata, and agent context.
  Survives terminal closure as long as the BEAM node runs.
  """
  use GenServer

  @table __MODULE__

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Store a file's AST metadata.
  """
  def put_ast(path, ast_data) do
    :ets.insert(@table, {{:ast, path}, ast_data})
    :ok
  end

  @doc """
  Get a file's AST metadata.
  """
  def get_ast(path) do
    case :ets.lookup(@table, {:ast, path}) do
      [{{:ast, ^path}, data}] -> {:ok, data}
      [] -> :error
    end
  end

  @doc """
  Get all indexed files with their AST metadata.
  """
  def all_asts do
    :ets.match_object(@table, {{:ast, :_}, :_})
    |> Enum.map(fn {{:ast, path}, data} -> {path, data} end)
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
  Clear all AST data (for re-indexing).
  """
  def clear_asts do
    :ets.match_delete(@table, {{:ast, :_}, :_})
    :ok
  end

  @doc """
  Get stats about the store.
  """
  def stats do
    ast_count =
      :ets.match(@table, {{:ast, :_}, :_})
      |> length()

    %{
      ast_files: ast_count,
      total_entries: :ets.info(@table, :size)
    }
  end

  @doc """
  Debug function to inspect what's actually in ETS.
  Call this to see the raw data structure.
  """
  def debug_inspect do
    require Logger

    all = all_asts()
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

  This is how Giulia answers "What modules do I have?" without reading files.
  """
  def list_modules do
    all_asts()
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
  List all functions in the indexed project.
  Returns a list of {module, function, arity} tuples.
  """
  def list_functions do
    all_asts()
    |> Enum.flat_map(fn {path, ast_data} ->
      functions = ast_data[:functions] || []
      modules = ast_data[:modules] || []
      module_name = List.first(modules)[:name] || "Unknown"

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
    end)
    |> Enum.sort_by(&{&1.module, &1.name, &1.arity})
  end

  @doc """
  Find a specific module by name.
  Returns {:ok, %{file: path, ast_data: data}} or :not_found.
  """
  def find_module(module_name) do
    all_asts()
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
  Find a specific function by name (optionally with arity).
  Returns a list of matches across all modules.
  """
  def find_function(function_name, arity \\ nil) do
    list_functions()
    |> Enum.filter(fn func ->
      name_match = to_string(func.name) == to_string(function_name)
      arity_match = arity == nil or func.arity == arity
      name_match and arity_match
    end)
  end

  @doc """
  Generate a compact project summary for LLM context injection.
  This is the "distilled metadata" strategy for small models.
  """
  def project_summary do
    modules = list_modules()
    functions = list_functions()
    stats = stats()

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

    Modules:
    #{module_summaries}
    """
  end

  # Server Callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
