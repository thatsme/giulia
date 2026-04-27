defmodule Giulia.Enrichment.IngestTest do
  use ExUnit.Case, async: false

  alias Giulia.Enrichment.{Ingest, Reader, Registry}
  alias Giulia.Persistence.Store

  setup do
    project =
      Path.join(
        System.tmp_dir!(),
        "giulia_ingest_test_#{:erlang.unique_integer([:positive])}"
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

  defp write_credo_payload(project, issues) do
    payload_path = Path.join(project, "credo.json")
    File.write!(payload_path, Jason.encode!(%{"issues" => issues}))
    payload_path
  end

  describe "run/3" do
    test "returns {:ok, summary} for a valid Credo payload", %{project: project} do
      payload =
        write_credo_payload(project, [
          %{
            "category" => "warning",
            "check" => "Credo.Check.Warning.IExPry",
            "filename" => "lib/x.ex",
            "line_no" => 5,
            "message" => "msg",
            "priority" => 5,
            "scope" => "X.do_thing"
          }
        ])

      assert {:ok, %{ingested: 1, targets: 1, replaced: 0, tool: :credo}} =
               Ingest.run("credo", project, payload)

      result = Reader.fetch_for_module(project, "X")
      assert [%{check: "Credo.Check.Warning.IExPry", severity: :error}] = result[:credo]
    end

    test "second run replaces prior findings", %{project: project} do
      payload1 = write_credo_payload(project, [credo_issue("first")])
      {:ok, _} = Ingest.run("credo", project, payload1)

      payload2 = write_credo_payload(project, [credo_issue("second")])
      {:ok, summary} = Ingest.run("credo", project, payload2)

      assert summary.replaced == 1
      [f] = Reader.fetch_for_module(project, "X")[:credo]
      assert f.message == "second"
    end

    test "returns {:error, {:unknown_tool, _}} for unregistered tool",
         %{project: project} do
      payload = write_credo_payload(project, [])

      assert {:error, {:unknown_tool, "nonexistent_tool"}} =
               Ingest.run("nonexistent_tool", project, payload)
    end

    test "returns {:error, _} on malformed JSON without crashing",
         %{project: project} do
      bad_payload = Path.join(project, "bad.json")
      File.write!(bad_payload, "not json")

      assert {:error, {:read_or_decode_failed, _}} =
               Ingest.run("credo", project, bad_payload)
    end

    test "emits :ingest telemetry on success", %{project: project} do
      test_pid = self()
      handler_id = "test-#{:rand.uniform(1_000_000)}"

      :telemetry.attach(
        handler_id,
        [:giulia, :enrichment, :ingest],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_ingest, measurements, metadata})
        end,
        nil
      )

      try do
        payload = write_credo_payload(project, [credo_issue("hello")])
        Ingest.run("credo", project, payload)

        assert_receive {:telemetry_ingest, %{count: 1, replaced: 0}, %{tool: :credo}}, 1000
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits :parse_error telemetry on parse failure", %{project: project} do
      test_pid = self()
      handler_id = "test-#{:rand.uniform(1_000_000)}"

      :telemetry.attach(
        handler_id,
        [:giulia, :enrichment, :parse_error],
        fn _event, _m, metadata, _ -> send(test_pid, {:telemetry_err, metadata}) end,
        nil
      )

      try do
        bad = Path.join(project, "bad.json")
        File.write!(bad, "not json")
        Ingest.run("credo", project, bad)

        assert_receive {:telemetry_err, %{tool: "credo", project: _}}, 1000
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  defp credo_issue(message) do
    %{
      "category" => "refactor",
      "check" => "Credo.Check.X",
      "filename" => "lib/x.ex",
      "line_no" => 1,
      "message" => message,
      "priority" => 5,
      "scope" => "X.do_thing"
    }
  end
end
