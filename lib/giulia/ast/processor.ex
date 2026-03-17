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

  @type module_info :: %{name: String.t(), line: non_neg_integer(), moduledoc: String.t() | nil}
  @type function_info :: %{name: atom(), arity: non_neg_integer(), type: :def | :defp | :defmacro | :defmacrop | :defdelegate | :defguard | :defguardp, line: non_neg_integer(), complexity: non_neg_integer()}
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
  defdelegate extract_modules(ast), to: Giulia.AST.Extraction

  @doc "Extract function definitions from AST."
  defdelegate extract_functions(ast), to: Giulia.AST.Extraction

  @doc "Extract imports, aliases, uses, and requires from AST."
  defdelegate extract_imports(ast), to: Giulia.AST.Extraction

  @doc "Extract type definitions from AST."
  defdelegate extract_types(ast), to: Giulia.AST.Extraction

  @doc "Extract @spec definitions from AST."
  defdelegate extract_specs(ast), to: Giulia.AST.Extraction

  @doc "Extract @callback definitions from AST."
  defdelegate extract_callbacks(ast), to: Giulia.AST.Extraction

  @doc "Extract @optional_callbacks as MapSet."
  defdelegate extract_optional_callbacks(ast), to: Giulia.AST.Extraction

  @doc "Extract defstruct definitions from AST."
  defdelegate extract_structs(ast), to: Giulia.AST.Extraction

  @doc "Extract @doc definitions from AST."
  defdelegate extract_docs(ast), to: Giulia.AST.Extraction

  @doc "Extract @moduledoc from a module."
  defdelegate extract_moduledoc(ast), to: Giulia.AST.Extraction

  # ============================================================================
  # Analysis delegates
  # ============================================================================

  @doc "Analyze an AST and extract structured metadata."
  defdelegate analyze(ast, source), to: Giulia.AST.Analysis

  @doc "Analyze a file and return structured metadata."
  defdelegate analyze_file(path), to: Giulia.AST.Analysis

  @doc "Generate a compact summary for LLM context."
  defdelegate summarize(info), to: Giulia.AST.Analysis

  @doc "Generate a detailed summary with function signatures."
  defdelegate detailed_summary(info), to: Giulia.AST.Analysis

  @doc "Count source lines."
  defdelegate count_lines(source), to: Giulia.AST.Analysis

  @doc "Estimate code complexity based on control flow (module-level, legacy)."
  defdelegate estimate_complexity(ast), to: Giulia.AST.Analysis

  @doc "Compute per-function cognitive complexity for all functions in a file AST."
  defdelegate compute_function_complexities(ast), to: Giulia.AST.Complexity, as: :compute_all

  @doc "Compute cognitive complexity for a single function body AST."
  defdelegate cognitive_complexity(ast), to: Giulia.AST.Complexity

  @doc "Quick test function to verify extraction works."
  defdelegate test_extraction(), to: Giulia.AST.Analysis

  @doc "Debug function to analyze a real file and show AST structure."
  defdelegate debug_file(path), to: Giulia.AST.Analysis

  # ============================================================================
  # Slicer delegates
  # ============================================================================

  @doc "Extract only a specific function from source code."
  defdelegate slice_function(source, name, arity), to: Giulia.AST.Slicer

  @doc "Extract a function and its direct dependencies."
  defdelegate slice_function_with_deps(source, name, arity), to: Giulia.AST.Slicer

  @doc "Slice source to only include lines around an error location."
  # defdelegate doesn't forward default args — handle /2 explicitly
  def slice_around_line(source, line), do: Giulia.AST.Slicer.slice_around_line(source, line, 10)
  defdelegate slice_around_line(source, line, context_lines), to: Giulia.AST.Slicer

  @doc "Create a minimal context for a specific error."
  defdelegate slice_for_error(source, error_line, error_message), to: Giulia.AST.Slicer

  # ============================================================================
  # Patcher delegates
  # ============================================================================

  @doc "Patch a specific function in the source code."
  defdelegate patch_function(source, function_name, arity, new_body), to: Giulia.AST.Patcher

  @doc "Insert a new function into a module."
  defdelegate insert_function(source, module_name, function_source), to: Giulia.AST.Patcher

  @doc "Get the source range for a specific function."
  defdelegate get_function_range(ast, function_name, arity), to: Giulia.AST.Patcher
end
