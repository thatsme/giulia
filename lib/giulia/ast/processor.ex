defmodule Giulia.AST.Processor do
  @moduledoc """
  Facade for AST analysis — delegates to focused sub-modules.

  - `Giulia.AST.Extraction` — module/function/import/type/spec/callback/struct/doc extraction
  - `Giulia.AST.Analysis` — analyze, summarize, complexity, debug helpers
  - `Giulia.AST.Slicer` — function slicing, line-range slicing, error context
  - `Giulia.AST.Patcher` — patch, insert, and locate functions in source

  Parsing (`parse/1`, `parse_file/1`) and all type definitions live here.
  All public functions are delegated — zero breaking changes for callers.
  """

  # ============================================================================
  # Types
  # ============================================================================

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

  @type module_info :: %{name: String.t(), line: non_neg_integer(), moduledoc: String.t() | false | nil, impl_for: String.t() | nil}
  @type function_info :: %{name: atom(), module: String.t(), arity: non_neg_integer(), min_arity: non_neg_integer(), type: :def | :defp | :defmacro | :defmacrop | :defdelegate | :defguard | :defguardp, line: non_neg_integer(), complexity: non_neg_integer()}
  @type import_info :: %{type: :import | :alias | :use | :require, module: String.t(), line: non_neg_integer()}
  @type type_info :: %{name: atom(), arity: non_neg_integer(), visibility: :type | :typep | :opaque, line: non_neg_integer(), definition: String.t()}
  @type spec_info :: %{function: atom(), arity: non_neg_integer(), spec: String.t(), line: non_neg_integer()}
  @type callback_info :: %{function: atom(), arity: non_neg_integer(), spec: String.t(), optional: boolean(), line: non_neg_integer()}
  @type struct_info :: %{module: String.t(), fields: [atom()], line: non_neg_integer()}
  @type doc_info :: %{function: atom(), arity: non_neg_integer(), doc: String.t(), line: non_neg_integer()}

  # ============================================================================
  # Parsing (delegated to AST.Parser — shared with Analysis)
  # ============================================================================

  @spec parse(String.t()) :: parse_result()
  defdelegate parse(source), to: Giulia.AST.Parser

  @spec parse_file(String.t()) :: parse_result()
  defdelegate parse_file(path), to: Giulia.AST.Parser

  # ============================================================================
  # Extraction delegates
  # ============================================================================

  @doc "Extract module definitions from AST."
  @spec extract_modules(Macro.t()) :: [module_info()]
  defdelegate extract_modules(ast), to: Giulia.AST.Extraction

  @doc "Extract function definitions from AST."
  @spec extract_functions(Macro.t()) :: [function_info()]
  defdelegate extract_functions(ast), to: Giulia.AST.Extraction

  @doc "Extract imports, aliases, uses, and requires from AST."
  @spec extract_imports(Macro.t()) :: [import_info()]
  defdelegate extract_imports(ast), to: Giulia.AST.Extraction

  @doc "Extract type definitions from AST."
  @spec extract_types(Macro.t()) :: [type_info()]
  defdelegate extract_types(ast), to: Giulia.AST.Extraction

  @doc "Extract @spec definitions from AST."
  @spec extract_specs(Macro.t()) :: [spec_info()]
  defdelegate extract_specs(ast), to: Giulia.AST.Extraction

  @doc "Extract @callback definitions from AST."
  @spec extract_callbacks(Macro.t()) :: [callback_info()]
  defdelegate extract_callbacks(ast), to: Giulia.AST.Extraction

  @doc "Extract @optional_callbacks as MapSet."
  @spec extract_optional_callbacks(Macro.t()) :: MapSet.t({atom(), non_neg_integer()})
  defdelegate extract_optional_callbacks(ast), to: Giulia.AST.Extraction

  @doc "Extract defstruct definitions from AST."
  @spec extract_structs(Macro.t()) :: [struct_info()]
  defdelegate extract_structs(ast), to: Giulia.AST.Extraction

  @doc "Extract @doc definitions from AST."
  @spec extract_docs(Macro.t()) :: [doc_info()]
  defdelegate extract_docs(ast), to: Giulia.AST.Extraction

  @doc "Extract @moduledoc from a module. `false` is preserved (distinct from `nil`) because `@moduledoc false` is a deliberate opt-out signal."
  @spec extract_moduledoc(Macro.t()) :: String.t() | false | nil
  defdelegate extract_moduledoc(ast), to: Giulia.AST.Extraction

  # ============================================================================
  # Analysis delegates
  # ============================================================================

  @doc "Analyze an AST and extract structured metadata."
  @spec analyze(Macro.t(), String.t()) :: file_info()
  defdelegate analyze(ast, source), to: Giulia.AST.Analysis

  @doc "Analyze a file and return structured metadata."
  @spec analyze_file(String.t()) :: {:ok, file_info()} | {:error, term()}
  defdelegate analyze_file(path), to: Giulia.AST.Analysis

  @doc "Generate a compact summary for LLM context."
  @spec summarize(file_info()) :: String.t()
  defdelegate summarize(info), to: Giulia.AST.Analysis

  @doc "Generate a detailed summary with function signatures."
  @spec detailed_summary(file_info()) :: String.t()
  defdelegate detailed_summary(info), to: Giulia.AST.Analysis

  @doc "Count source lines."
  @spec count_lines(String.t()) :: non_neg_integer()
  defdelegate count_lines(source), to: Giulia.AST.Analysis

  @doc "Estimate code complexity based on control flow (module-level, legacy)."
  @spec estimate_complexity(Macro.t()) :: non_neg_integer()
  defdelegate estimate_complexity(ast), to: Giulia.AST.Analysis

  @doc "Compute per-function cognitive complexity for all functions in a file AST."
  @spec compute_function_complexities(Macro.t()) :: %{{atom(), non_neg_integer()} => non_neg_integer()}
  defdelegate compute_function_complexities(ast), to: Giulia.AST.Complexity, as: :compute_all

  @doc "Compute cognitive complexity for a single function body AST."
  @spec cognitive_complexity(Macro.t()) :: non_neg_integer()
  defdelegate cognitive_complexity(ast), to: Giulia.AST.Complexity

  @doc "Quick test function to verify extraction works."
  @spec test_extraction() :: %{modules: [module_info()], functions: [function_info()]} | {:error, term()}
  defdelegate test_extraction(), to: Giulia.AST.Analysis

  @doc "Debug function to analyze a real file and show AST structure."
  @spec debug_file(String.t()) :: %{modules: [module_info()], functions: [function_info()]} | {:error, :parse_failed | :read_failed}
  defdelegate debug_file(path), to: Giulia.AST.Analysis

  # ============================================================================
  # Slicer delegates
  # ============================================================================

  @doc "Extract only a specific function from source code."
  @spec slice_function(String.t(), atom(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defdelegate slice_function(source, name, arity), to: Giulia.AST.Slicer

  @doc "Extract a function and its direct dependencies."
  @spec slice_function_with_deps(String.t(), atom(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defdelegate slice_function_with_deps(source, name, arity), to: Giulia.AST.Slicer

  @doc "Slice source to only include lines around an error location."
  # defdelegate doesn't forward default args — handle /2 explicitly
  @spec slice_around_line(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  @spec slice_around_line(String.t(), non_neg_integer()) :: String.t()
  def slice_around_line(source, line), do: Giulia.AST.Slicer.slice_around_line(source, line, 10)
  defdelegate slice_around_line(source, line, context_lines), to: Giulia.AST.Slicer

  @doc "Create a minimal context for a specific error."
  @spec slice_for_error(String.t(), non_neg_integer(), String.t()) :: String.t()
  defdelegate slice_for_error(source, error_line, error_message), to: Giulia.AST.Slicer

  # ============================================================================
  # Patcher delegates
  # ============================================================================

  @doc "Patch a specific function in the source code."
  @spec patch_function(String.t(), atom(), non_neg_integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate patch_function(source, function_name, arity, new_body), to: Giulia.AST.Patcher

  @doc "Insert a new function into a module."
  @spec insert_function(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate insert_function(source, module_name, function_source), to: Giulia.AST.Patcher

  @doc "Get the source range for a specific function."
  @spec get_function_range(Macro.t(), atom(), non_neg_integer()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | :not_found
  defdelegate get_function_range(ast, function_name, arity), to: Giulia.AST.Patcher
end
