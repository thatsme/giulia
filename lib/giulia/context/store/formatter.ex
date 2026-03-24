defmodule Giulia.Context.Store.Formatter do
  @moduledoc """
  Formatted text output for LLM context injection.

  Generates human-readable project summaries and module details
  from indexed AST data. Used by the daemon API and prompt builder.

  Extracted from `Context.Store` (Build 111).
  """

  alias Giulia.Context.Store.Query

  # Types inlined to avoid circular dependency (Store delegates to Formatter)
  @type project_path :: String.t()
  @type module_name :: String.t()

  # ETS table name — same as Store's @table
  @table Giulia.Context.Store

  @doc """
  Generate a compact project summary for LLM context injection.
  """
  @spec project_summary(project_path()) :: String.t()
  def project_summary(project_path) do
    modules = Query.list_modules(project_path)
    functions = Query.list_functions(project_path, nil)
    types = Query.list_types(project_path, nil)
    specs = Query.list_specs(project_path, nil)
    structs = Query.list_structs(project_path)
    callbacks = Query.list_callbacks(project_path, nil)
    stats = stats(project_path)

    public_functions =
      functions
      |> Enum.filter(&(&1.type in [:def, :defmacro, :defdelegate, :defguard]))
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
  @spec module_details(project_path(), module_name()) :: String.t()
  def module_details(project_path, module_name) do
    case Query.find_module(project_path, module_name) do
      {:ok, %{file: file, ast_data: ast_data}} ->
        modules = ast_data[:modules] || []
        mod = Enum.find(modules, &(&1.name == module_name))

        functions = Query.list_functions(project_path, module_name)
        types = Query.list_types(project_path, module_name)
        specs = Query.list_specs(project_path, module_name)
        callbacks = Query.list_callbacks(project_path, module_name)
        struct_info = Query.get_struct(project_path, module_name)

        public_funcs = Enum.filter(functions, &(&1.type in [:def, :defmacro, :defdelegate, :defguard]))
        private_funcs = Enum.filter(functions, &(&1.type in [:defp, :defmacrop, :defguardp]))

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

  # Direct ETS read — avoids routing through Store (cycle breaker)
  defp stats(project_path) do
    ast_count =
      :ets.match_object(@table, {{:ast, project_path, :_}, :_})
      |> length()

    %{ast_files: ast_count, total_entries: :ets.info(@table, :size)}
  end
end
