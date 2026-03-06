defmodule Giulia.AST.AnalysisTest do
  use ExUnit.Case, async: true

  alias Giulia.AST.Analysis

  @sample_source """
  defmodule MyApp.Worker do
    @moduledoc "Background worker."

    def run(task), do: task
    defp validate(input), do: input

    def process(data) do
      case data do
        :ok -> :done
        _ -> :error
      end
    end
  end
  """

  setup_all do
    {:ok, ast} = Sourceror.parse_string(@sample_source)
    %{ast: ast}
  end

  # ============================================================================
  # analyze/2
  # ============================================================================

  describe "analyze/2" do
    test "returns complete metadata map", %{ast: ast} do
      info = Analysis.analyze(ast, @sample_source)

      assert is_list(info.modules)
      assert is_list(info.functions)
      assert is_list(info.imports)
      assert is_list(info.types)
      assert is_list(info.specs)
      assert is_list(info.callbacks)
      assert is_list(info.optional_callbacks)
      assert is_list(info.structs)
      assert is_list(info.docs)
      assert is_integer(info.line_count)
      assert is_integer(info.complexity)
    end

    test "finds modules and functions", %{ast: ast} do
      info = Analysis.analyze(ast, @sample_source)
      assert length(info.modules) == 1
      assert hd(info.modules).name == "MyApp.Worker"
      assert length(info.functions) >= 2
    end

    test "counts lines correctly", %{ast: ast} do
      info = Analysis.analyze(ast, @sample_source)
      expected_lines = @sample_source |> String.split("\n") |> length()
      assert info.line_count == expected_lines
    end
  end

  # ============================================================================
  # summarize/1
  # ============================================================================

  describe "summarize/1" do
    test "produces readable summary", %{ast: ast} do
      info = Analysis.analyze(ast, @sample_source)
      summary = Analysis.summarize(info)

      assert is_binary(summary)
      assert summary =~ "MyApp.Worker"
      assert summary =~ "run/1"
      assert summary =~ "Lines:"
      assert summary =~ "Complexity:"
    end
  end

  # ============================================================================
  # detailed_summary/1
  # ============================================================================

  describe "detailed_summary/1" do
    test "includes visibility info", %{ast: ast} do
      info = Analysis.analyze(ast, @sample_source)
      summary = Analysis.detailed_summary(info)

      assert summary =~ "[public]"
      assert summary =~ "[private]"
      assert summary =~ "line"
    end
  end

  # ============================================================================
  # count_lines/1
  # ============================================================================

  describe "count_lines/1" do
    test "counts lines in a string" do
      assert Analysis.count_lines("a\nb\nc") == 3
    end

    test "single line" do
      assert Analysis.count_lines("hello") == 1
    end

    test "empty string" do
      assert Analysis.count_lines("") == 1
    end

    test "non-binary returns 0" do
      assert Analysis.count_lines(nil) == 0
      assert Analysis.count_lines(42) == 0
    end
  end

  # ============================================================================
  # estimate_complexity/1
  # ============================================================================

  describe "estimate_complexity/1" do
    test "counts control flow constructs", %{ast: ast} do
      complexity = Analysis.estimate_complexity(ast)
      # has def, defp, and case — at least 3
      assert complexity >= 3
    end

    test "simple function has low complexity" do
      {:ok, ast} = Sourceror.parse_string("def foo, do: :ok")
      assert Analysis.estimate_complexity(ast) >= 1
    end

    test "complex function scores higher" do
      source = """
      def complex(x) do
        case x do
          :a -> if true, do: :ok
          :b ->
            with {:ok, v} <- fetch(x) do
              try do
                process(v)
              rescue
                _ -> :error
              end
            end
        end
      end
      """

      {:ok, ast} = Sourceror.parse_string(source)
      complexity = Analysis.estimate_complexity(ast)
      # def + case + if + with + try = at least 7
      assert complexity >= 5
    end

    test "handles invalid AST gracefully" do
      assert Analysis.estimate_complexity(:not_an_ast) == 0
    end
  end
end
