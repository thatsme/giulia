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

  Primarily asserts the INPUT side (typed args reaching Store). Where an endpoint
  has no protocol-specific response shaping, it also asserts full-body equality.
  The former `:schema_version` divergence on `pre_impact_check` (REST-only stamp)
  is now closed — the stamp is single-sourced in `Knowledge.Facade`, so both
  protocols carry it and the bodies match. Zero known REST/MCP divergences.
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

      # Convergence: :schema_version is now stamped once in Knowledge.Facade, so
      # both protocols carry it and the FULL bodies match. (Was: REST-only stamp,
      # MCP lacked it — the last known divergence, now closed.)
      assert Map.has_key?(rest, "schema_version")
      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
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

  describe "otp_risks — REST/MCP parity through facade" do
    test "ready: identical body" do
      rest = rest_get("/api/knowledge/otp_risks", path: @project_path)
      assert {:ok, mcp} = Dispatch.Knowledge.otp_risks(%{"path" => @project_path})

      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
    end

    test "check filter and suppress are coerced once, in the facade" do
      params = [path: @project_path, check: "blocking_init", suppress: "blocking_init:Foo.Bar"]
      rest = rest_get("/api/knowledge/otp_risks", params)

      assert {:ok, mcp} =
               Dispatch.Knowledge.otp_risks(%{
                 "path" => @project_path,
                 "check" => "blocking_init",
                 "suppress" => "blocking_init:Foo.Bar"
               })

      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
      assert rest["check_filter"] == "blocking_init"
    end

    test "unscanned path: MCP carries the scan hint (shared readiness via Edge)" do
      assert {:error, msg} = Dispatch.Knowledge.otp_risks(%{"path" => @unscanned})
      assert msg =~ "scan"
    end
  end

  describe "supervision — REST/MCP parity through facade" do
    test "ready: identical body (no params to drift, but shape must still match)" do
      rest = rest_get("/api/knowledge/supervision", path: @project_path)
      assert {:ok, mcp} = Dispatch.Knowledge.supervision(%{"path" => @project_path})

      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
    end

    test "unscanned path: MCP carries the scan hint (shared readiness via Edge)" do
      assert {:error, msg} = Dispatch.Knowledge.supervision(%{"path" => @unscanned})
      assert msg =~ "scan"
    end
  end

  describe "search/semantic — REST/MCP parity through Search.Facade" do
    test "valid concept: REST and MCP agree on the canonical shape (was divergent)" do
      rest_conn =
        conn(:get, "/api/search/semantic?path=#{@project_path}&concept=graph+traversal")
        |> Endpoint.call(@opts)

      mcp = Dispatch.Search.semantic(%{"path" => @project_path, "concept" => "graph traversal"})

      # Convergence: before the facade, REST reshaped + count=functions-only while
      # MCP emitted raw structs + count=total — different shape AND count. Now both
      # render the one canonical shape (reshaped modules/functions, count = total).
      case mcp do
        {:ok, body} ->
          assert rest_conn.status == 200
          decoded = Jason.decode!(rest_conn.resp_body)
          assert decoded == body |> Jason.encode!() |> Jason.decode!()
          # the count bugfix: total, not functions-only
          assert body.count == length(body.modules) + length(body.functions)

        {:error, _} ->
          assert rest_conn.status in [404, 500, 503]
      end
    end

    test "unscanned path: MCP carries the scan hint (shared readiness via Edge)" do
      assert {:error, msg} = Dispatch.Search.semantic(%{"path" => @unscanned, "concept" => "x"})
      assert msg =~ "scan"
    end
  end

  describe "duplicates — REST/MCP parity, two readiness dimensions" do
    # Two orthogonal not-ready dimensions (scan-readiness via the edge,
    # embedding-availability via the facade) + the results path. All three use
    # CONTROLLED embedding state — never the project's real (large, shared)
    # embedding set: find_duplicates is O(n^2) over function embeddings, so
    # running it on ~2000+ functions made this test slow and flaky. Seed a
    # bounded fixture for the results path; clear for the unavailable path.

    test "not-scanned: both signal scan-readiness with the scan hint" do
      rest =
        conn(:get, "/api/knowledge/duplicates?path=#{@unscanned}")
        |> Endpoint.call(@opts)

      assert rest.status == 409
      assert Jason.decode!(rest.resp_body)["hint"] =~ "scan"

      assert {:error, msg} = Dispatch.Knowledge.duplicates(%{"path" => @unscanned})
      assert msg =~ "scan"
    end

    test "scanned + bounded embeddings: REST and MCP return identical clusters" do
      # Three function embeddings: two with identical vectors (cluster), one
      # orthogonal (does not). Deterministic single cluster of size 2.
      #
      # `SemanticIndex` (semantic_index.ex:230) and `Persistence.Loader`
      # (loader.ex:155) both write function embeddings for this project from
      # BACKGROUND processes. `async: false` does not constrain them — they are
      # app GenServers, not test processes — so a re-index landing between the
      # two protocol calls swaps the fixture for the project's real ~2000-entry
      # set. Observed once in 13 full-suite runs: REST returned the fixtures and
      # MCP returned real functions, and the assertion reported a 60-line diff
      # of two unrelated cluster sets that looked like a parity defect.
      #
      # Re-seed immediately before each call so both read the same data, and
      # verify the fixture actually survived. This tests parity — that the two
      # protocols agree on one input — which is not what a race can tell us.
      seed_function_embeddings(@project_path, bounded_function_embeddings())
      assert_fixture_intact!("before REST")
      rest = rest_get("/api/knowledge/duplicates", path: @project_path, max: 5)

      Giulia.Context.Store.put_embeddings(
        @project_path,
        :function,
        bounded_function_embeddings()
      )

      assert_fixture_intact!("before MCP")
      assert {:ok, mcp} = Dispatch.Knowledge.duplicates(%{"path" => @project_path, "max" => "5"})

      assert rest == mcp |> Jason.encode!() |> Jason.decode!()
      assert mcp.count == 1
      assert [%{size: 2}] = mcp.clusters
    end

    test "scanned + no embeddings: both signal embedding-unavailable (query the worker)" do
      clear_and_restore_embeddings(@project_path)

      rest =
        conn(:get, "/api/knowledge/duplicates?path=#{@project_path}")
        |> Endpoint.call(@opts)

      assert rest.status == 503
      assert Jason.decode!(rest.resp_body)["error"] =~ "query the worker"

      assert {:error, msg} = Dispatch.Knowledge.duplicates(%{"path" => @project_path})
      assert msg =~ "query the worker"
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

  # Bounded, deterministic function-embedding fixture: two identical 384-d unit
  # vectors (cosine 1.0 -> cluster) + one orthogonal (cosine 0 -> no cluster).
  # find_duplicates over these 3 is instant — vs O(n^2) over the real ~2000.
  defp bounded_function_embeddings do
    a = [1.0 | List.duplicate(0.0, 383)]
    c = [0.0, 1.0 | List.duplicate(0.0, 382)]

    [
      fixture_embedding("Fix.dup_a/0", "Fix", "dup_a", a),
      fixture_embedding("Fix.dup_b/0", "Fix", "dup_b", a),
      fixture_embedding("Fix.solo/0", "Fix", "solo", c)
    ]
  end

  # Fail with the cause rather than with a diff of two unrelated cluster sets.
  # If a background re-index has replaced the fixture, say so by name — the
  # alternative is a parity assertion failing for a reason that has nothing to
  # do with parity.
  defp assert_fixture_intact!(when_label) do
    # `get_embeddings/2` returns `{:ok, entries} | :error` — see the
    # `restore_function_embeddings/2` clauses below. Matching a bare list here
    # silently reported an empty fixture that was in fact intact.
    ids =
      case Giulia.Context.Store.get_embeddings(@project_path, :function) do
        {:ok, entries} when is_list(entries) -> Enum.map(entries, & &1.id)
        entries when is_list(entries) -> Enum.map(entries, & &1.id)
        _ -> []
      end

    assert Enum.sort(ids) == ["Fix.dup_a/0", "Fix.dup_b/0", "Fix.solo/0"],
           "seeded embedding fixture was replaced #{when_label} — a background " <>
             "SemanticIndex/Loader write raced this test. Got #{length(ids)} entries."
  end

  defp fixture_embedding(id, mod, func, vec) do
    %{
      id: id,
      vector: Nx.to_binary(Nx.tensor(vec, type: :f32)),
      metadata: %{module: mod, function: func, arity: 0, file: "#{mod}.ex", line: 1}
    }
  end

  # Overwrite the project's function embeddings with a fixture for the duration
  # of one test; restore the original state on exit (readiness still passes since
  # the project is really scanned — only the embedding set is swapped).
  defp seed_function_embeddings(path, entries) do
    saved = Giulia.Context.Store.get_embeddings(path, :function)
    Giulia.Context.Store.put_embeddings(path, :function, entries)
    on_exit(fn -> restore_function_embeddings(path, saved) end)
  end

  defp clear_and_restore_embeddings(path) do
    saved = Giulia.Context.Store.get_embeddings(path, :function)
    Giulia.Context.Store.clear_embeddings(path)
    on_exit(fn -> restore_function_embeddings(path, saved) end)
  end

  defp restore_function_embeddings(path, {:ok, entries}),
    do: Giulia.Context.Store.put_embeddings(path, :function, entries)

  defp restore_function_embeddings(path, :error),
    do: Giulia.Context.Store.clear_embeddings(path)

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
