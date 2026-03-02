defmodule Giulia.Daemon.HelpersTest do
  @moduledoc """
  Tests for Daemon.Helpers — shared utility functions for all routers (degree 12).

  Pure functions: parse_int_param, parse_float_param, format_fracture.
  Plug-dependent: send_json, resolve_project_path, parse_node_param.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Giulia.Daemon.Helpers

  # ============================================================================
  # parse_int_param/2
  # ============================================================================

  describe "parse_int_param/2" do
    test "returns default for nil" do
      assert Helpers.parse_int_param(nil, 42) == 42
    end

    test "parses integer string" do
      assert Helpers.parse_int_param("10", 0) == 10
    end

    test "parses integer with trailing text" do
      assert Helpers.parse_int_param("5abc", 0) == 5
    end

    test "returns default for non-numeric string" do
      assert Helpers.parse_int_param("abc", 99) == 99
    end

    test "handles integer input" do
      assert Helpers.parse_int_param(7, 0) == 7
    end

    test "parses negative integers" do
      assert Helpers.parse_int_param("-3", 0) == -3
    end
  end

  # ============================================================================
  # parse_float_param/2
  # ============================================================================

  describe "parse_float_param/2" do
    test "returns default for nil" do
      assert Helpers.parse_float_param(nil, 1.0) == 1.0
    end

    test "parses float string" do
      assert Helpers.parse_float_param("3.14", 0.0) == 3.14
    end

    test "parses integer string as float" do
      assert Helpers.parse_float_param("5", 0.0) == 5.0
    end

    test "returns default for non-numeric string" do
      assert Helpers.parse_float_param("abc", 0.5) == 0.5
    end
  end

  # ============================================================================
  # format_fracture/1
  # ============================================================================

  describe "format_fracture/1" do
    test "formats a full fracture map" do
      fracture = %{
        implementer: "MyModule",
        missing: [{:foo, 2}, {:bar, 1}],
        injected: [{:baz, 0}],
        optional_omitted: [{:qux, 3}],
        heuristic_injected: []
      }

      result = Helpers.format_fracture(fracture)

      assert result.implementer == "MyModule"
      assert "foo/2" in result.missing
      assert "bar/1" in result.missing
      assert "baz/0" in result.injected
      assert "qux/3" in result.optional_omitted
      assert result.heuristic_injected == []
    end

    test "handles empty lists gracefully" do
      fracture = %{
        implementer: "Empty",
        missing: [],
        injected: [],
        optional_omitted: [],
        heuristic_injected: []
      }

      result = Helpers.format_fracture(fracture)
      assert result.missing == []
      assert result.injected == []
    end

    test "handles missing keys with defaults" do
      fracture = %{implementer: "Partial"}
      result = Helpers.format_fracture(fracture)
      assert result.implementer == "Partial"
      assert result.missing == []
    end
  end

  # ============================================================================
  # send_json/3
  # ============================================================================

  describe "send_json/3" do
    test "sends JSON response with correct content type" do
      conn = conn(:get, "/test")
      result = Helpers.send_json(conn, 200, %{status: "ok"})

      assert result.status == 200
      assert get_resp_header(result, "content-type") |> hd() =~ "application/json"
      assert Jason.decode!(result.resp_body) == %{"status" => "ok"}
    end

    test "sends error response with 400 status" do
      conn = conn(:get, "/test")
      result = Helpers.send_json(conn, 400, %{error: "bad request"})

      assert result.status == 400
      assert Jason.decode!(result.resp_body) == %{"error" => "bad request"}
    end
  end

  # ============================================================================
  # resolve_project_path/1
  # ============================================================================

  describe "resolve_project_path/1" do
    test "returns nil when path param is missing" do
      conn = conn(:get, "/test") |> fetch_query_params()
      assert Helpers.resolve_project_path(conn) == nil
    end

    test "resolves path when param is present" do
      conn = conn(:get, "/test?path=D:/Development/GitHub/Giulia") |> fetch_query_params()
      result = Helpers.resolve_project_path(conn)
      assert is_binary(result)
      assert result != nil
    end
  end

  # ============================================================================
  # parse_node_param/1
  # ============================================================================

  describe "parse_node_param/1" do
    test "returns :local for missing node param" do
      conn = conn(:get, "/test") |> fetch_query_params()
      assert Helpers.parse_node_param(conn) == :local
    end

    test "returns :local for empty string" do
      conn = conn(:get, "/test?node=") |> fetch_query_params()
      assert Helpers.parse_node_param(conn) == :local
    end

    test "converts node string to atom" do
      conn = conn(:get, "/test?node=myapp@localhost") |> fetch_query_params()
      assert Helpers.parse_node_param(conn) == :"myapp@localhost"
    end
  end
end
