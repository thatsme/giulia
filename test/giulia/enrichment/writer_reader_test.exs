defmodule Giulia.Enrichment.WriterReaderTest do
  use ExUnit.Case, async: false

  alias Giulia.Enrichment.{Reader, Registry, Writer}
  alias Giulia.Persistence.Store

  setup do
    project =
      Path.join(
        System.tmp_dir!(),
        "giulia_enrichment_rw_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(project)
    {:ok, _db} = Store.open(project)
    Registry.reload()

    on_exit(fn ->
      Store.close(project)
      File.rm_rf!(project)
    end)

    %{project: project}
  end

  defp finding(opts) do
    Map.merge(
      %{
        scope: :function,
        module: "Foo",
        function: "bar",
        arity: 1,
        severity: :warning,
        check: "Credo.Check.X",
        message: "msg",
        line: 10
      },
      Enum.into(opts, %{})
    )
  end

  describe "fetch_for_mfa/2 — never-ingested vs no-findings" do
    test "returns empty map %{} when no tool has been ingested", %{project: project} do
      assert Reader.fetch_for_mfa(project, "Foo.bar/1") == %{}
    end

    test "returns %{tool: []} after ingest with no findings on that MFA",
         %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding(module: "Other")])
      result = Reader.fetch_for_mfa(project, "Foo.bar/1")
      assert result == %{credo: []}
    end

    test "returns %{tool: [findings]} after ingest with matching MFA", %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding([])])
      result = Reader.fetch_for_mfa(project, "Foo.bar/1")
      assert [%{module: "Foo", function: "bar", arity: 1}] = result[:credo]
    end
  end

  describe "fetch_for_module/2" do
    test "returns module-scoped findings under the module key", %{project: project} do
      {:ok, _} =
        Writer.replace_for(:credo, project, [
          %{
            scope: :module,
            module: "Foo",
            severity: :warning,
            check: "X",
            message: "module-level",
            line: 1
          }
        ])

      result = Reader.fetch_for_module(project, "Foo")
      assert [%{message: "module-level"}] = result[:credo]
    end
  end

  describe "tools_ingested/1" do
    test "returns empty list before any ingest", %{project: project} do
      assert Reader.tools_ingested(project) == []
    end

    test "returns the tool atom after ingest", %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding([])])
      assert Reader.tools_ingested(project) == [:credo]
    end
  end

  describe "replace_for/3 — replace-on-ingest semantics" do
    test "second ingest replaces (does not append) prior findings", %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding(message: "first")])
      {:ok, summary} = Writer.replace_for(:credo, project, [finding(message: "second")])

      assert summary.replaced == 1
      assert summary.targets == 1
      assert summary.findings == 1

      [f] = Reader.fetch_for_mfa(project, "Foo.bar/1")[:credo]
      assert f.message == "second"
    end

    test "ingest of empty list deletes all prior findings", %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding([])])
      {:ok, summary} = Writer.replace_for(:credo, project, [])

      assert summary.replaced == 1
      assert Reader.fetch_for_mfa(project, "Foo.bar/1") == %{credo: []}
    end
  end

  describe "provenance stamping" do
    test "every finding gets provenance with tool, run_at, source_digest_at_run",
         %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding([])])
      [f] = Reader.fetch_for_mfa(project, "Foo.bar/1")[:credo]

      assert f.provenance.tool == :credo
      assert %DateTime{} = f.provenance.run_at
      # source_digest_at_run is nil unless the finding had a :file pointing
      # to an actual file (this fixture doesn't set :file).
      assert Map.has_key?(f.provenance, :source_digest_at_run)
    end

    test "resolution_ambiguous defaults to false when not set by parser",
         %{project: project} do
      {:ok, _} = Writer.replace_for(:credo, project, [finding([])])
      [f] = Reader.fetch_for_mfa(project, "Foo.bar/1")[:credo]
      assert f.resolution_ambiguous == false
    end

    test "resolution_ambiguous is preserved when set by parser", %{project: project} do
      ambiguous_finding =
        finding([])
        |> Map.put(:scope, :module)
        |> Map.put(:resolution_ambiguous, true)
        |> Map.delete(:function)
        |> Map.delete(:arity)

      {:ok, _} = Writer.replace_for(:credo, project, [ambiguous_finding])
      [f] = Reader.fetch_for_module(project, "Foo")[:credo]
      assert f.resolution_ambiguous == true
    end
  end
end
