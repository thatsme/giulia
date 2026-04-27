defmodule Giulia.Enrichment.Sources.DialyzerTest do
  use ExUnit.Case, async: false

  alias Giulia.Context.Store
  alias Giulia.Enrichment.{Registry, Sources}
  alias Sources.Dialyzer

  @project "/tmp/giulia_dialyzer_parser_test"

  setup do
    File.mkdir_p!(@project)
    Registry.reload()

    on_exit(fn ->
      Store.clear_asts(@project)
      File.rm_rf!(@project)
    end)

    :ok
  end

  defp put_fake_functions(file_rel, modules_funcs) do
    abs_path = Path.join(@project, file_rel)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, "# fake source\n")

    functions =
      Enum.flat_map(modules_funcs, fn {module, funcs} ->
        Enum.map(funcs, fn {name, arity, line} ->
          %{module: module, name: String.to_atom(name), arity: arity, line: line, type: :def}
        end)
      end)

    modules = Enum.map(modules_funcs, fn {m, _} -> %{name: m, line: 1} end)
    Store.put_ast(@project, abs_path, %{modules: modules, functions: functions})
    abs_path
  end

  defp write_payload(lines) do
    payload_path = Path.join(@project, "dialyzer.out")
    File.write!(payload_path, Enum.join(lines, "\n") <> "\n")
    payload_path
  end

  describe "parse/2 — error paths" do
    test "returns error on missing file" do
      assert {:error, {:read_failed, :enoent}} =
               Dialyzer.parse("/nonexistent/dialyzer.out", @project)
    end

    test "empty file returns empty findings" do
      payload = write_payload([])
      assert {:ok, []} = Dialyzer.parse(payload, @project)
    end

    test "lines that don't match the format are silently skipped" do
      payload =
        write_payload([
          "Finding suitable PLTs",
          "Total errors: 0, Skipped: 0, Unnecessary Skips: 7",
          "done in 0m0.84s"
        ])

      assert {:ok, []} = Dialyzer.parse(payload, @project)
    end
  end

  describe "format parsing" do
    test "line:col form" do
      payload = write_payload(["lib/x.ex:42:7:no_return Function quux/2 has no local return."])
      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.check == "no_return"
      assert finding.line == 42
      assert finding.column == 7
      assert finding.severity == :error
      assert finding.message == "Function quux/2 has no local return."
    end

    test "line-only form (no column)" do
      payload = write_payload(["lib/x.ex:17:pattern_match The pattern can never match the type t."])
      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.line == 17
      refute Map.has_key?(finding, :column)
      assert finding.check == "pattern_match"
    end
  end

  describe "severity mapping (driven by enrichment_sources.json)" do
    test "no_return → :error" do
      payload = write_payload(["lib/x.ex:1:no_return Function f/0 has no local return."])
      {:ok, [f]} = Dialyzer.parse(payload, @project)
      assert f.severity == :error
    end

    test "contract_subtype → :warning" do
      payload = write_payload(["lib/x.ex:1:contract_subtype Type spec is a subtype."])
      {:ok, [f]} = Dialyzer.parse(payload, @project)
      assert f.severity == :warning
    end

    test "unknown_function → :info" do
      payload = write_payload(["lib/x.ex:1:unknown_function Function Mod:fn/1 does not exist."])
      {:ok, [f]} = Dialyzer.parse(payload, @project)
      assert f.severity == :info
    end

    test "unknown warning_name falls back to default_severity (:warning)" do
      payload = write_payload(["lib/x.ex:1:made_up_warning Some weird thing."])
      {:ok, [f]} = Dialyzer.parse(payload, @project)
      assert f.severity == :warning
    end
  end

  describe "function-level resolution via line index" do
    test "single match in line range → function attach" do
      file = put_fake_functions("lib/foo.ex", [{"Foo", [{"bar", 2, 10}, {"baz", 1, 30}]}])
      payload = write_payload(["#{file}:15:no_return Function bar/2 has no local return."])

      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.scope == :function
      assert finding.module == "Foo"
      assert finding.function == "bar"
      assert finding.arity == 2
    end

    test "ambiguous (different function names cover the line) → module + flag" do
      file = put_fake_functions("lib/foo.ex", [{"Foo", [{"alpha", 0, 10}, {"beta", 0, 10}]}])
      payload = write_payload(["#{file}:10:pattern_match Pattern can never match."])

      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.scope == :module
      assert finding.resolution_ambiguous == true
    end

    test "no match → module-only attach via filename" do
      payload = write_payload(["lib/missing.ex:5:no_return Function f/0 has no return."])
      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.scope == :module
      assert finding.module == "Missing"
      refute Map.get(finding, :resolution_ambiguous, false)
    end

    test "Dialyzer relative path resolves against absolute paths in the index" do
      # Index keyed by absolute path; Dialyzer line uses relative path.
      put_fake_functions("lib/foo.ex", [{"Foo", [{"bar", 0, 10}]}])
      payload = write_payload(["lib/foo.ex:10:no_return Function bar/0 has no return."])

      {:ok, [finding]} = Dialyzer.parse(payload, @project)
      assert finding.scope == :function
      assert finding.function == "bar"
    end
  end
end
