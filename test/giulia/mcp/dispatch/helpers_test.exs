defmodule Giulia.MCP.Dispatch.HelpersTest do
  @moduledoc """
  Adversarial coverage for argument-coercion helpers shared across all
  MCP dispatch modules.

  Per `memory:feedback_integrity_pattern`, these helpers are exactly the
  kind of cross-cutting filter where silent over-match / under-match
  bugs hide. A regression in `parse_int` or `require_path` would silently
  break dispatch across nine categories at once, so each function gets
  the standard sample + count + filter-accountability triplet adapted
  to its shape.
  """

  use ExUnit.Case, async: true

  alias Giulia.MCP.Dispatch.Helpers

  describe "require_path/1" do
    test "errors when path key is absent" do
      assert {:error, "Missing required parameter: path"} = Helpers.require_path(%{})
    end

    test "errors when path key is explicitly nil" do
      assert {:error, "Missing required parameter: path"} = Helpers.require_path(%{"path" => nil})
    end

    test "passes through resolved path when present" do
      assert {:ok, resolved} = Helpers.require_path(%{"path" => "/projects/example"})
      assert is_binary(resolved)
    end
  end

  describe "require_param/2" do
    test "errors with the parameter name in the message" do
      assert {:error, "Missing required parameter: module"} =
               Helpers.require_param(%{}, "module")

      assert {:error, "Missing required parameter: q"} = Helpers.require_param(%{}, "q")
    end

    test "errors when the key exists but value is nil" do
      assert {:error, "Missing required parameter: module"} =
               Helpers.require_param(%{"module" => nil}, "module")
    end

    test "returns {:ok, value} for any non-nil value (strings, integers, lists)" do
      assert {:ok, "MyMod"} = Helpers.require_param(%{"module" => "MyMod"}, "module")
      assert {:ok, 42} = Helpers.require_param(%{"depth" => 42}, "depth")
      assert {:ok, ["a", "b"]} = Helpers.require_param(%{"xs" => ["a", "b"]}, "xs")
    end

    test "returns {:ok, value} for empty-string input — not a missing-param" do
      # The MCP layer treats empty string as "explicitly empty" and forwards
      # the responsibility to the underlying business-logic to reject it.
      # Conflating empty-string with nil here would mask intentional
      # "no-filter" passes downstream.
      assert {:ok, ""} = Helpers.require_param(%{"q" => ""}, "q")
    end
  end

  describe "resolve_node/1" do
    test "nil resolves to :local" do
      assert :local = Helpers.resolve_node(nil)
    end

    test "empty string resolves to :local" do
      assert :local = Helpers.resolve_node("")
    end

    test "invalid node names fall back to :local rather than raising" do
      # safe_to_node_atom rejects names without a host segment.
      assert :local = Helpers.resolve_node("not-a-node-name")
    end

    test "well-formed node names round-trip" do
      assert :giulia@localhost = Helpers.resolve_node("giulia@localhost")
    end
  end

  describe "parse_int/2" do
    test "nil → default" do
      assert 7 = Helpers.parse_int(nil, 7)
    end

    test "binary digits → integer" do
      assert 42 = Helpers.parse_int("42", 0)
      assert -3 = Helpers.parse_int("-3", 0)
    end

    test "binary with trailing junk → leading integer" do
      # Integer.parse stops at first non-digit; document this as the
      # contract so the MCP /api callers know "42abc" → 42, not default.
      assert 42 = Helpers.parse_int("42abc", 0)
    end

    test "non-numeric binary → default" do
      assert 0 = Helpers.parse_int("abc", 0)
      assert 5 = Helpers.parse_int("", 5)
    end

    test "integer passthrough" do
      assert 42 = Helpers.parse_int(42, 0)
      assert 0 = Helpers.parse_int(0, 99)
    end

    test "float / map / list → default (no silent truncation)" do
      assert 7 = Helpers.parse_int(1.5, 7)
      assert 7 = Helpers.parse_int(%{}, 7)
      assert 7 = Helpers.parse_int([1, 2], 7)
    end
  end

  describe "parse_float/2" do
    test "nil → default" do
      assert 0.5 = Helpers.parse_float(nil, 0.5)
    end

    test "binary float → float" do
      assert 0.85 = Helpers.parse_float("0.85", 0.0)
      assert 1.0 = Helpers.parse_float("1.0", 0.0)
    end

    test "non-numeric binary → default" do
      assert 0.5 = Helpers.parse_float("not-a-float", 0.5)
      assert 0.5 = Helpers.parse_float("", 0.5)
    end

    test "float passthrough" do
      assert 0.85 = Helpers.parse_float(0.85, 0.0)
    end

    test "integer / map → default (does not coerce int→float)" do
      # Integer 42 is not a float — return default rather than silently
      # coercing. Caller passes integer threshold ⇒ programmer error,
      # surfaces as default rather than hidden type drift.
      assert 0.5 = Helpers.parse_float(42, 0.5)
      assert 0.5 = Helpers.parse_float(%{}, 0.5)
    end
  end

  describe "parse_suppress/1" do
    test "nil → empty map" do
      assert %{} == Helpers.parse_suppress(nil)
    end

    test "empty string → empty map" do
      assert %{} == Helpers.parse_suppress("")
    end

    test "single rule with single module" do
      assert %{"rule_a" => ["Mod.A"]} == Helpers.parse_suppress("rule_a:Mod.A")
    end

    test "single rule with multiple comma-separated modules" do
      assert %{"rule_a" => ["Mod.A", "Mod.B", "Mod.C"]} ==
               Helpers.parse_suppress("rule_a:Mod.A,Mod.B,Mod.C")
    end

    test "multiple rules separated by semicolons" do
      assert %{"r1" => ["A"], "r2" => ["B", "C"]} ==
               Helpers.parse_suppress("r1:A;r2:B,C")
    end

    test "trims whitespace inside module list" do
      assert %{"r" => ["A", "B"]} == Helpers.parse_suppress("r: A , B ")
    end

    test "drops segments without `:`" do
      # "noop" lacks a colon — silently dropped, the other valid entry
      # still parses. Strict here would break ergonomic copy-paste from
      # docs that include trailing semicolons.
      assert %{"r" => ["A"]} == Helpers.parse_suppress("noop;r:A")
    end

    test "drops rules whose module list is empty after trimming" do
      assert %{} == Helpers.parse_suppress("r:")
      assert %{} == Helpers.parse_suppress("r: , , ")
    end

    test "non-binary input → empty map (defensive)" do
      assert %{} == Helpers.parse_suppress(%{})
      assert %{} == Helpers.parse_suppress([:a, :b])
      assert %{} == Helpers.parse_suppress(123)
    end
  end
end
