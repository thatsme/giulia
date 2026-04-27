defmodule Giulia.Enrichment.Sources.CredoTest do
  use ExUnit.Case, async: false

  alias Giulia.Context.Store
  alias Giulia.Enrichment.{Registry, Sources}
  alias Sources.Credo

  @project "/tmp/giulia_credo_parser_test"

  setup do
    File.mkdir_p!(@project)
    # Severity mapping now lives in priv/config/enrichment_sources.json;
    # reload so the registry reflects the on-disk config exactly even
    # if a prior test mutated :persistent_term.
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

    modules =
      Enum.map(modules_funcs, fn {m, _} -> %{name: m, line: 1} end)

    Store.put_ast(@project, abs_path, %{modules: modules, functions: functions})
    abs_path
  end

  defp write_payload(issues) do
    payload_path = Path.join(@project, "credo.json")
    File.write!(payload_path, Jason.encode!(%{"issues" => issues}))
    payload_path
  end

  describe "parse/2 — error paths" do
    test "returns error on missing file" do
      assert {:error, {:read_or_decode_failed, :enoent}} =
               Credo.parse("/nonexistent/credo.json", @project)
    end

    test "returns error on malformed JSON" do
      payload_path = Path.join(@project, "bad.json")
      File.write!(payload_path, "not json {{{")
      assert {:error, {:read_or_decode_failed, _}} = Credo.parse(payload_path, @project)
    end

    test "returns error on unexpected JSON shape" do
      payload_path = Path.join(@project, "weird.json")
      File.write!(payload_path, ~s({"not_issues": []}))
      assert {:error, {:unexpected_shape, _}} = Credo.parse(payload_path, @project)
    end

    test "empty issues list returns empty findings list" do
      payload_path = write_payload([])
      assert {:ok, []} = Credo.parse(payload_path, @project)
    end
  end

  describe "severity mapping" do
    test "category 'warning' maps to :error (the Credo naming inversion)" do
      payload_path =
        write_payload([
          %{
            "category" => "warning",
            "check" => "Credo.Check.Warning.IExPry",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "IEx.pry/0 left in code",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.severity == :error
    end

    test "category 'design' maps to :warning" do
      payload_path =
        write_payload([
          %{
            "category" => "design",
            "check" => "Credo.Check.Design.AliasUsage",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.severity == :warning
    end

    test "category 'refactor' maps to :warning" do
      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "Credo.Check.Refactor.CyclomaticComplexity",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.severity == :warning
    end

    test "category 'readability' maps to :info" do
      payload_path =
        write_payload([
          %{
            "category" => "readability",
            "check" => "Credo.Check.Readability.PredicateFunctionNames",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.severity == :info
    end

    test "unknown category falls back to :info" do
      payload_path =
        write_payload([
          %{
            "category" => "frobnication",
            "check" => "Credo.Check.X",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.severity == :info
    end
  end

  describe "three-path arity resolution" do
    test "single match — line falls inside one function: function-scope attach" do
      file = put_fake_functions("lib/foo.ex", [{"Foo", [{"bar", 2, 10}, {"baz", 1, 30}]}])

      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "Credo.Check.Refactor.X",
            "filename" => file,
            "line_no" => 15,
            "message" => "x",
            "priority" => 5,
            "scope" => "Foo.bar"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.scope == :function
      assert finding.module == "Foo"
      assert finding.function == "bar"
      assert finding.arity == 2
      refute Map.get(finding, :resolution_ambiguous, false)
    end

    test "multi-arity (same name): attaches to first matching arity" do
      # bar/2 (line 10..19) and bar/3 (line 20..29). A line at 25
      # falls inside bar/3 only — but if scope is "Foo.bar" with line
      # spanning both, it's still single-match. Build a pathological
      # case: clauses adjacent so a line might match either, by line
      # range derivation: bar/2 ends at 19 (next func line - 1). Pick
      # line 19 as the test target — falls in bar/2.
      file = put_fake_functions("lib/foo.ex", [{"Foo", [{"bar", 2, 10}, {"bar", 3, 20}]}])

      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "X",
            "filename" => file,
            "line_no" => 19,
            "message" => "x",
            "priority" => 5,
            "scope" => "Foo.bar"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.scope == :function
      assert finding.function == "bar"
      assert finding.arity == 2
    end

    test "ambiguous (different names overlap): module attach + resolution_ambiguous flag" do
      # Two functions with different names whose line ranges contain
      # the credo-reported line. Real-world: macro-generated functions.
      # We synthesize this by putting two funcs with same start line.
      file = put_fake_functions("lib/foo.ex", [{"Foo", [{"alpha", 0, 10}, {"beta", 0, 10}]}])

      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "X",
            "filename" => file,
            "line_no" => 10,
            "message" => "x",
            "priority" => 5,
            "scope" => "Foo.alpha"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.scope == :module
      assert finding.module == "Foo"
      assert finding.resolution_ambiguous == true
    end

    test "all-arities fallback: line resolution misses but scope parses" do
      # No functions in our index for the file. Line resolution finds 0,
      # falls through to all-arities pass which also finds nothing →
      # module-only attach.
      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "X",
            "filename" => "lib/missing.ex",
            "line_no" => 50,
            "message" => "x",
            "priority" => 5,
            "scope" => "Missing.never_indexed"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.scope == :module
      assert finding.module == "Missing"
    end

    test "module-only scope (no function segment)" do
      payload_path =
        write_payload([
          %{
            "category" => "refactor",
            "check" => "X",
            "filename" => "lib/x.ex",
            "line_no" => 1,
            "message" => "x",
            "priority" => 5,
            "scope" => "Mix.Tasks.CreateFreeSubscription"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.scope == :module
      assert finding.module == "Mix.Tasks.CreateFreeSubscription"
    end
  end

  describe "column persistence" do
    test "column and column_end are persisted when present" do
      payload_path =
        write_payload([
          %{
            "category" => "readability",
            "check" => "X",
            "filename" => "lib/x.ex",
            "line_no" => 5,
            "column" => 7,
            "column_end" => 21,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      assert finding.column == 7
      assert finding.column_end == 21
    end

    test "missing column / column_end fields are dropped, not nil" do
      payload_path =
        write_payload([
          %{
            "category" => "readability",
            "check" => "X",
            "filename" => "lib/x.ex",
            "line_no" => 5,
            "message" => "x",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      {:ok, [finding]} = Credo.parse(payload_path, @project)
      refute Map.has_key?(finding, :column)
      refute Map.has_key?(finding, :column_end)
    end
  end
end
