defmodule Giulia.AST.Analysis do
  @moduledoc """
  AST analysis and summarization — analyze/2 orchestrates metadata extraction,
  complexity estimation, and summary generation for LLM context.

  Depends on `Giulia.AST.Extraction` for extract_* calls and
  `Giulia.AST.Processor.parse_file/1` for file reading.
  """

  alias Giulia.AST.{Complexity, Extraction}

  # ============================================================================
  # Core Analysis
  # ============================================================================

  @doc """
  Analyze an AST and extract structured metadata.
  """
  @spec analyze(Macro.t(), String.t()) :: Giulia.AST.Processor.file_info()
  def analyze(ast, source) do
    require Logger

    ast_type = case ast do
      {type, _meta, _args} when is_atom(type) -> "3-tuple with type: #{type}"
      {type, _meta, _args, _extra} -> "4-tuple with type: #{type}"
      list when is_list(list) -> "list with #{length(list)} elements"
      other -> "unexpected: #{inspect(other, limit: 2)}"
    end
    Logger.info("ANALYZE: AST is #{ast_type}")

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

    modules = Extraction.extract_modules(ast)
    Logger.info("ANALYZE: got #{length(modules)} modules")

    raw_functions = Extraction.extract_functions(ast)
    Logger.info("ANALYZE: got #{length(raw_functions)} functions")

    # Enrich functions with per-function cognitive complexity
    complexity_map = Complexity.compute_all(ast)

    functions =
      Enum.map(raw_functions, fn func ->
        complexity = Map.get(complexity_map, {func.name, func.arity}, 0)
        Map.put(func, :complexity, complexity)
      end)

    types = Extraction.extract_types(ast)
    specs = Extraction.extract_specs(ast)
    callbacks = Extraction.extract_callbacks(ast)
    optional_callbacks = Extraction.extract_optional_callbacks(ast)
    structs = Extraction.extract_structs(ast)
    docs = Extraction.extract_docs(ast)

    %{
      modules: modules,
      functions: functions,
      imports: Extraction.extract_imports(ast),
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

  @doc """
  Analyze a file and return structured metadata.
  """
  @spec analyze_file(String.t()) :: {:ok, Giulia.AST.Processor.file_info()} | {:error, term()}
  def analyze_file(path) do
    with {:ok, ast, source} <- Giulia.AST.Processor.parse_file(path) do
      info = analyze(ast, source) |> Map.put(:path, path)
      {:ok, info}
    end
  end

  # ============================================================================
  # Summaries
  # ============================================================================

  @doc """
  Generate a compact summary for LLM context.
  """
  @spec summarize(Giulia.AST.Processor.file_info()) :: String.t()
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
  @spec detailed_summary(Giulia.AST.Processor.file_info()) :: String.t()
  def detailed_summary(info) do
    module_section =
      info.modules
      |> Enum.map_join("\n", fn m -> "  - #{m.name} (line #{m.line})" end)

    function_section =
      info.functions
      |> Enum.map_join("\n", fn f ->
        visibility = if f.type in [:def, :defmacro, :defdelegate, :defguard], do: "public", else: "private"
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
  # Metrics
  # ============================================================================

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
  @spec estimate_complexity(Macro.t()) :: non_neg_integer()
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
  # Debug / Testing
  # ============================================================================

  @doc """
  Quick test function to verify extraction works.
  Call from iex: Giulia.AST.Analysis.test_extraction()
  """
  @spec test_extraction() :: %{modules: [Giulia.AST.Processor.module_info()], functions: [Giulia.AST.Processor.function_info()]} | {:error, term()}
  def test_extraction do
    require Logger

    source = """
    defmodule TestModule do
      def hello(name), do: "Hello, \#{name}!"

      defp private_func, do: :ok
    end
    """

    Logger.info("=== TEST EXTRACTION ===")
    Logger.info("Parsing source...")

    case Giulia.AST.Processor.parse(source) do
      {:ok, ast, _src} ->
        Logger.info("AST parsed successfully")
        Logger.info("AST structure: #{inspect(ast, pretty: true, limit: 5)}")

        Logger.info("=== DIRECT PATTERN MATCH TEST ===")
        case ast do
          {:defmodule, _meta, [{:__aliases__, _, parts} | _]} ->
            Logger.info("DIRECT MATCH SUCCESS: defmodule with aliases #{inspect(parts)}")
          {:defmodule, _meta, args} ->
            Logger.info("DIRECT MATCH PARTIAL: defmodule but args = #{inspect(args, limit: 3)}")
          other ->
            Logger.info("DIRECT MATCH FAILED: top level is #{inspect(other, limit: 3)}")
        end

        modules = Extraction.extract_modules(ast)
        functions = Extraction.extract_functions(ast)

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
  @spec debug_file(String.t()) :: %{modules: [Giulia.AST.Processor.module_info()], functions: [Giulia.AST.Processor.function_info()]} | {:error, :parse_failed | :read_failed}
  def debug_file(path) do
    require Logger

    Logger.info("=== DEBUG FILE: #{path} ===")

    case File.read(path) do
      {:ok, source} ->
        Logger.info("File read OK, #{byte_size(source)} bytes")

        case Sourceror.parse_string(source) do
          {:ok, ast} ->
            Logger.info("Parse OK")

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

            modules = Extraction.extract_modules(ast)
            functions = Extraction.extract_functions(ast)

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
  # Private
  # ============================================================================

  defp safe_count_lines(source) when is_binary(source) do
    source |> String.split("\n") |> length()
  end

  defp safe_count_lines(_), do: 0
end
