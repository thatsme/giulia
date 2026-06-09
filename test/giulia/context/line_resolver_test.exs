defmodule Giulia.Context.LineResolverTest do
  @moduledoc """
  Unit tests for the shared line -> vertex resolver.

  These exercise `candidates_for_line/3` and `resolve_module/3` against
  hand-built indexes — the pure core that both the enrichment correlator and
  the conventions analyzer rely on. The invariant under protection: a line
  resolves to the module of the function that *contains* it, even when one file
  declares several modules (co-located exceptions, multiple schemas). This is
  the regression that caused conventions to attribute every finding to the
  file's first module.
  """
  use ExUnit.Case, async: true

  alias Giulia.Context.LineResolver

  # Analog of lib/plug/router/utils.ex: two zero-function exception modules
  # occupy the top of the file, the real module owns everything from line 9 on.
  # The exception modules contribute NO function entries to the index.
  defp utils_index do
    %{
      "utils.ex" => [
        %{
          module: "Plug.Router.Utils",
          function: "build_path_match",
          arity: 1,
          line_start: 9,
          line_end: 120
        },
        %{
          module: "Plug.Router.Utils",
          function: "split",
          arity: 1,
          line_start: 121,
          line_end: :infinity
        }
      ]
    }
  end

  describe "candidates_for_line/3" do
    test "returns the entry whose range contains the line" do
      [entry] = LineResolver.candidates_for_line(utils_index(), "utils.ex", 79)
      assert entry.module == "Plug.Router.Utils"
      assert entry.function == "build_path_match"
    end

    test "is inclusive of line_start (boundary)" do
      assert [%{function: "build_path_match"}] =
               LineResolver.candidates_for_line(utils_index(), "utils.ex", 9)
    end

    test "is inclusive of line_end (boundary)" do
      assert [%{function: "build_path_match"}] =
               LineResolver.candidates_for_line(utils_index(), "utils.ex", 120)
    end

    test "the last function extends to :infinity" do
      assert [%{function: "split"}] =
               LineResolver.candidates_for_line(utils_index(), "utils.ex", 999_999)
    end

    test "a line before the first function resolves to nothing" do
      # Lines 1-8 belong to the zero-function exception modules — no entry covers them.
      assert [] = LineResolver.candidates_for_line(utils_index(), "utils.ex", 3)
    end

    test "unknown file yields []" do
      assert [] = LineResolver.candidates_for_line(utils_index(), "ghost.ex", 50)
    end

    test "empty index yields []" do
      assert [] = LineResolver.candidates_for_line(%{}, "utils.ex", 50)
    end

    test "nil file yields []" do
      assert [] = LineResolver.candidates_for_line(utils_index(), nil, 50)
    end

    test "nil line yields []" do
      assert [] = LineResolver.candidates_for_line(utils_index(), "utils.ex", nil)
    end
  end

  describe "resolve_module/3 — multi-module attribution (the bug)" do
    test "a finding inside the real module is NOT attributed to a leading exception module" do
      # The collaudo case: L79 in utils.ex must resolve to Plug.Router.Utils,
      # never to the file's first-declared module (an exception type).
      assert LineResolver.resolve_module(utils_index(), "utils.ex", 79) == "Plug.Router.Utils"
    end

    test "a line inside a later module resolves to that module, not an earlier sibling" do
      # Two modules in one file; the finding sits in the second.
      index = %{
        "multi.ex" => [
          %{module: "App.First", function: "a", arity: 0, line_start: 5, line_end: 40},
          %{module: "App.Second", function: "b", arity: 1, line_start: 50, line_end: :infinity}
        ]
      }

      assert LineResolver.resolve_module(index, "multi.ex", 60) == "App.Second"
      assert LineResolver.resolve_module(index, "multi.ex", 10) == "App.First"
    end

    test "co-located exceptions (zero functions) receive nothing; the host module owns the lines" do
      # Analog of lib/plug/conn.ex: nested exception modules declared between
      # Plug.Conn functions but carrying no defs of their own. A finding on a
      # line deep in the file resolves to Plug.Conn.
      index = %{
        "conn.ex" => [
          %{
            module: "Plug.Conn",
            function: "put_resp_header",
            arity: 3,
            line_start: 300,
            line_end: 500
          },
          %{
            module: "Plug.Conn",
            function: "get_req_header",
            arity: 2,
            line_start: 501,
            line_end: :infinity
          }
        ]
      }

      assert LineResolver.resolve_module(index, "conn.ex", 414) == "Plug.Conn"
    end

    test "returns nil when no function covers the line" do
      assert LineResolver.resolve_module(utils_index(), "utils.ex", 3) == nil
    end

    test "returns nil for unknown file" do
      assert LineResolver.resolve_module(utils_index(), "ghost.ex", 10) == nil
    end
  end
end
