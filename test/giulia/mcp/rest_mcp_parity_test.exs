defmodule Giulia.MCP.RestMcpParityTest do
  @moduledoc """
  REST/MCP parameter-contract parity.

  Both protocols front the same internal handlers (`Giulia.Knowledge.Store`).
  The MCP layer is meant to be a THIN PROXY: forward params to the shared
  layer, not re-implement required-ness/defaults/coercion. This suite is the
  guarantee whose absence let REST and MCP drift independently:

    * Valid input: the SAME input through the REST path and the MCP path must
      reach Store with identical typed args (asserted via identical
      Store-derived results — module echoed, same set, same count).
    * Missing required: both paths must reject. After deleting MCP's redundant
      `require_param` gates (Store backstops with `{:not_found}` etc.), MCP must
      still reject — the param did not silently become optional. REST keeps its
      own 400-at-the-edge gate (deliberate: edge validation stays at the edge).

  Note: this asserts the INPUT side (typed args reaching Store), NOT identical
  final responses — REST stamps `:schema_version` on `pre_impact_check` and MCP
  does not (a known shape divergence deferred to the facade commit). Comparing
  full responses would flag that, which is not what these tests guard.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Giulia.Daemon.Endpoint
  alias Giulia.MCP.Dispatch

  @opts Endpoint.init([])
  @project_path "/projects/Giulia"

  setup do
    unless ready?(@project_path) do
      Giulia.Context.Indexer.scan(@project_path)
      wait_for_scan_completion(@project_path, 60_000)
    end

    :ok
  end

  describe "dependents — REST/MCP input parity" do
    test "valid module: both paths reach Store with identical args (identical result)" do
      module = "Giulia.Knowledge.Store"

      rest = rest_get("/api/knowledge/dependents", path: @project_path, module: module)

      assert {:ok, mcp} =
               Dispatch.Knowledge.dependents(%{"path" => @project_path, "module" => module})

      assert rest["module"] == mcp.module
      assert rest["count"] == mcp.count
      assert Enum.sort(rest["dependents"]) == Enum.sort(mcp.dependents)
    end

    test "missing module: both paths reject (required-ness survives gate deletion)" do
      # REST: 400 at the edge.
      assert rest_status("/api/knowledge/dependents", path: @project_path) == 400

      # MCP: no edge gate anymore — Store backstops nil module with {:not_found}.
      assert {:error, _} = Dispatch.Knowledge.dependents(%{"path" => @project_path})
    end
  end

  describe "dependencies — REST/MCP input parity" do
    test "valid module: both paths reach Store with identical args (identical result)" do
      module = "Giulia.Knowledge.Store"

      rest = rest_get("/api/knowledge/dependencies", path: @project_path, module: module)

      assert {:ok, mcp} =
               Dispatch.Knowledge.dependencies(%{"path" => @project_path, "module" => module})

      assert rest["module"] == mcp.module
      assert rest["count"] == mcp.count
      assert Enum.sort(rest["dependencies"]) == Enum.sort(mcp.dependencies)
    end

    test "missing module: both paths reject (required-ness survives gate deletion)" do
      assert rest_status("/api/knowledge/dependencies", path: @project_path) == 400
      assert {:error, _} = Dispatch.Knowledge.dependencies(%{"path" => @project_path})
    end
  end

  describe "centrality — REST/MCP input parity" do
    test "valid module: both paths reach Store with identical args (identical result)" do
      module = "Giulia.Knowledge.Store"

      rest = rest_get("/api/knowledge/centrality", path: @project_path, module: module)

      assert {:ok, mcp} =
               Dispatch.Knowledge.centrality(%{"path" => @project_path, "module" => module})

      assert rest["module"] == mcp.module
      assert rest["in_degree"] == mcp.in_degree
      assert rest["out_degree"] == mcp.out_degree
    end

    test "missing module: both paths reject (required-ness survives gate deletion)" do
      assert rest_status("/api/knowledge/centrality", path: @project_path) == 400
      assert {:error, _} = Dispatch.Knowledge.centrality(%{"path" => @project_path})
    end
  end

  describe "pre_impact_check — REST/MCP input parity (POST body)" do
    test "valid input: response bodies identical except REST's :schema_version stamp" do
      body = %{
        "path" => @project_path,
        "module" => "Giulia.Knowledge.Store",
        "action" => "remove_function",
        "target" => "stats/1"
      }

      rest = rest_post("/api/knowledge/pre_impact_check", body)
      assert {:ok, mcp} = Dispatch.Knowledge.pre_impact_check(body)

      # MCP forwards the same map to Store; REST stamps :schema_version AFTER
      # Store returns. So the Store call is identical and the bodies match once
      # the (deferred-to-facade) stamp is removed. Normalize MCP atom keys via a
      # JSON round-trip to compare against the decoded REST JSON.
      rest_core = Map.delete(rest, "schema_version")
      mcp_core = mcp |> Jason.encode!() |> Jason.decode!()

      assert Map.has_key?(rest, "schema_version"),
             "guard: REST is expected to stamp schema_version until the facade folds it in"

      assert rest_core == mcp_core
    end

    test "missing action: both paths reject (required-ness survives gate deletion)" do
      body = %{"path" => @project_path, "module" => "Giulia.Knowledge.Store"}

      assert rest_post_status("/api/knowledge/pre_impact_check", body) == 400
      assert {:error, _} = Dispatch.Knowledge.pre_impact_check(body)
    end
  end

  describe "impact — REST/MCP parity through Knowledge.Facade (ready)" do
    test "valid module: identical normalized body (one depth default, one normalizer)" do
      rest =
        rest_get("/api/knowledge/impact", path: @project_path, module: "Giulia.Knowledge.Store")

      assert {:ok, mcp} =
               Dispatch.Knowledge.impact(%{
                 "path" => @project_path,
                 "module" => "Giulia.Knowledge.Store"
               })

      # No schema_version on impact — full bodies must match.
      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
    end

    test "ready project, missing module: both reject (module gate fires after readiness)" do
      assert rest_status("/api/knowledge/impact", path: @project_path) == 400
      assert {:error, _} = Dispatch.Knowledge.impact(%{"path" => @project_path})
    end
  end

  describe "impact — REST/MCP readiness parity (not-ready)" do
    # An unscanned path: REST already 409s with a scan hint; MCP must too, via
    # the facade's readiness step (the (a) behavior change). Before that wiring
    # MCP returned a bare not-found with no actionable hint — the divergence
    # this asserts away. Failing-when-fixed: red until MCP carries the hint.
    @unscanned "/projects/__unscanned_for_parity__"

    test "unscanned path: both surfaces signal not-ready with the actionable scan hint" do
      rest =
        conn(:get, "/api/knowledge/impact?path=#{@unscanned}&module=Foo")
        |> Endpoint.call(@opts)

      assert rest.status == 409
      assert Jason.decode!(rest.resp_body)["hint"] =~ "scan"

      assert {:error, msg} =
               Dispatch.Knowledge.impact(%{"path" => @unscanned, "module" => "Foo"})

      assert msg =~ "scan",
             "MCP must carry the actionable scan hint, not a bare not-found: #{inspect(msg)}"
    end
  end

  describe "style_oracle — REST/MCP parity through facade" do
    test "valid q: REST and MCP agree (identical body when embedded; same error otherwise)" do
      rest_conn =
        conn(:get, "/api/knowledge/style_oracle?path=#{@project_path}&q=graph+traversal")
        |> Endpoint.call(@opts)

      mcp = Dispatch.Knowledge.style_oracle(%{"path" => @project_path, "q" => "graph traversal"})

      # Parity = agreement, not a specific status. The fixture may or may not have
      # embeddings built; either way both surfaces reach the same outcome through
      # the shared facade. style_oracle SIGNALS missing embeddings loudly (error +
      # hint), unlike the silent-empty that makes duplicates the open question.
      case mcp do
        {:ok, body} ->
          assert rest_conn.status == 200
          assert Jason.decode!(rest_conn.resp_body) == body |> Jason.encode!() |> Jason.decode!()

        {:error, _msg} ->
          assert rest_conn.status in [500, 503]
      end
    end

    test "ready project, missing q: both reject (q gate fires after readiness)" do
      assert rest_status("/api/knowledge/style_oracle", path: @project_path) == 400
      assert {:error, _} = Dispatch.Knowledge.style_oracle(%{"path" => @project_path})
    end

    test "unscanned path: MCP carries the scan hint (shared readiness via Edge)" do
      assert {:error, msg} = Dispatch.Knowledge.style_oracle(%{"path" => @unscanned, "q" => "x"})
      assert msg =~ "scan"
    end
  end

  describe "unprotected_hubs — REST/MCP parity through facade" do
    test "ready: identical body (one threshold-default pair, both protocols)" do
      rest = rest_get("/api/knowledge/unprotected_hubs", path: @project_path)
      assert {:ok, mcp} = Dispatch.Knowledge.unprotected_hubs(%{"path" => @project_path})

      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
    end

    test "unscanned path: MCP carries the scan hint (shared readiness via Edge)" do
      assert {:error, msg} = Dispatch.Knowledge.unprotected_hubs(%{"path" => @unscanned})
      assert msg =~ "scan"
    end
  end

  describe "conventions — REST/MCP input parity (shared parse_suppress)" do
    test "same path + suppress: identical result (one parse_suppress, both protocols)" do
      suppress = "process_dictionary:Giulia.Knowledge.Store"

      rest = rest_get("/api/knowledge/conventions", path: @project_path, suppress: suppress)

      assert {:ok, mcp} =
               Dispatch.Knowledge.conventions(%{"path" => @project_path, "suppress" => suppress})

      # No schema_version on conventions — full bodies must match.
      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rest_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Endpoint.call(@opts)
    |> then(fn conn ->
      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      Jason.decode!(conn.resp_body)
    end)
  end

  defp rest_post_status(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Endpoint.call(@opts)
    |> Map.fetch!(:status)
  end

  defp rest_get(path, params) do
    query = URI.encode_query(params)

    conn(:get, "#{path}?#{query}")
    |> Endpoint.call(@opts)
    |> then(fn conn ->
      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      Jason.decode!(conn.resp_body)
    end)
  end

  defp rest_status(path, params) do
    query = URI.encode_query(params)

    conn(:get, "#{path}?#{query}")
    |> Endpoint.call(@opts)
    |> Map.fetch!(:status)
  end

  defp ready?(path) do
    case Giulia.Context.Indexer.status(path) do
      %{status: :scanning} -> false
      %{file_count: n} when n > 0 -> graph_ready?(path)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp graph_ready?(path) do
    stats = Giulia.Knowledge.Store.stats(path)
    is_integer(stats.vertices) and stats.vertices > 0
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp wait_for_scan_completion(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(path, deadline)
  end

  defp do_wait(path, deadline) do
    cond do
      ready?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("setup scan/graph-build timed out for #{path}")

      true ->
        Process.sleep(500)
        do_wait(path, deadline)
    end
  end
end
