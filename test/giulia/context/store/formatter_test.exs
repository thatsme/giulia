defmodule Giulia.Context.Store.FormatterTest do
  use ExUnit.Case, async: false

  alias Giulia.Context.Store
  alias Giulia.Context.Store.Formatter

  @test_path "/tmp/formatter_test_#{:rand.uniform(10000)}"

  setup do
    # Table already exists from app supervisor — just seed data
    ast_data = %{
      modules: [%{name: "MyApp.Worker", line: 1, moduledoc: "Does work."}],
      functions: [
        %{name: :run, arity: 1, type: :def, line: 3},
        %{name: :stop, arity: 0, type: :def, line: 8},
        %{name: :internal, arity: 0, type: :defp, line: 12}
      ],
      imports: [],
      types: [],
      specs: [%{function: :run, arity: 1, spec: "run(term()) :: :ok", line: 2}],
      callbacks: [],
      optional_callbacks: [],
      structs: [],
      docs: [],
      line_count: 15,
      complexity: 2
    }

    Store.put_ast(@test_path, "lib/my_app/worker.ex", ast_data)

    on_exit(fn -> Store.clear_asts(@test_path) end)

    %{path: @test_path}
  end

  describe "project_summary/1" do
    test "includes module and function info", %{path: path} do
      summary = Formatter.project_summary(path)
      assert summary =~ "PROJECT INDEX"
      assert summary =~ "MyApp.Worker"
      assert summary =~ "run/1"
      assert summary =~ "stop/0"
      # Private functions should not appear in summary (only public)
      refute summary =~ "internal/0"
    end

    test "includes counts", %{path: path} do
      summary = Formatter.project_summary(path)
      assert summary =~ "Files: 1"
      assert summary =~ "Modules: 1"
      assert summary =~ "Functions: 3"
    end
  end

  describe "module_details/2" do
    test "returns detailed module info", %{path: path} do
      details = Formatter.module_details(path, "MyApp.Worker")
      assert details =~ "MyApp.Worker"
      assert details =~ "worker.ex"
      assert details =~ "Public functions"
      assert details =~ "Private functions"
      assert details =~ "run/1"
    end

    test "returns not found message for missing module", %{path: path} do
      result = Formatter.module_details(path, "Nope")
      assert result =~ "not found"
    end
  end
end
