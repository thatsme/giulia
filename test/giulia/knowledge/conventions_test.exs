defmodule Giulia.Knowledge.ConventionsTest do
  @moduledoc """
  Filter-accountability tests for `Conventions.walk_ast/3`.

  The three `check_try_rescue_flow_control` branches each use
  `String.contains?(Macro.to_string(node), "<literal>")` to decide whether
  a `try/rescue` block contains a disallowed call. Substring match on
  source text is the same silent-over-match shape that bit
  `Indexer.ignored?/1` and `ToolSchema.mcp_compatible?/1`: it fires on
  any occurrence of the literal in the source, including string literals
  inside the body, not just real calls.

  Dual-assertion discipline:
    * Drop-side — each branch's trigger (real call inside try/rescue)
      must emit a `try_rescue_flow_control` violation.
    * Pass-through — the trigger literal appearing in a string literal,
      function name fragment, or OUTSIDE any try/rescue must NOT emit
      the violation.

  `walk_ast/3` is exposed `@doc false` for test harnessing; it is the
  pure AST-prewalk entry (Tier 2 checks only), unaffected by ETS state
  or filesystem I/O.
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Conventions

  defp walk!(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    Conventions.walk_ast(ast, "test.ex", "Test")
  end

  defp has_rule?(violations, rule) do
    Enum.any?(violations, fn v -> v.rule == rule end)
  end

  describe "check_try_rescue_flow_control — drop-side accountability" do
    @drop_fixtures [
      {"Repo.get! call inside try/rescue",
       """
       defmodule X do
         def f(id) do
           try do
             Repo.get!(User, id)
           rescue
             _ -> :ok
           end
         end
       end
       """},
      {"String.to_integer call inside try/rescue",
       """
       defmodule X do
         def f(s) do
           try do
             String.to_integer(s)
           rescue
             _ -> 0
           end
         end
       end
       """},
      {"String.to_float call inside try/rescue",
       """
       defmodule X do
         def f(s) do
           try do
             String.to_float(s)
           rescue
             _ -> 0.0
           end
         end
       end
       """}
    ]

    for {label, source} <- @drop_fixtures do
      @tag label: label
      test "flags: #{label}" do
        violations = walk!(unquote(source))

        assert has_rule?(violations, "try_rescue_flow_control"),
               "drop-fixture should emit try_rescue_flow_control but violations were: " <>
                 inspect(violations, limit: :infinity)
      end
    end
  end

  describe "check_try_rescue_flow_control — pass-through accountability" do
    # Each fixture is a module whose AST prewalk MUST NOT emit
    # `try_rescue_flow_control`. Over-match regressions show up here:
    # the fixture looks innocuous, but a naive `String.contains?` check
    # on `Macro.to_string(node)` wrongly fires.
    @pass_through_fixtures [
      # Literal "Repo.get!" inside a string inside a try body. The
      # production check does `String.contains?(source, "Repo.get!")`
      # where `source = Macro.to_string(node)`; that source text
      # includes the string literal verbatim, so the check silently
      # flags this as a violation even though no call is made.
      {"Repo.get! substring only in a string literal inside try",
       """
       defmodule X do
         def f do
           try do
             _ = "use Repo.get! please"
           rescue
             _ -> :ok
           end
         end
       end
       """},
      {"String.to_integer substring only in a string literal inside try",
       """
       defmodule X do
         def f do
           try do
             _ = "avoid String.to_integer here"
           rescue
             _ -> :ok
           end
         end
       end
       """},
      {"String.to_float substring only in a string literal inside try",
       """
       defmodule X do
         def f do
           try do
             _ = "String.to_float is bad"
           rescue
             _ -> :ok
           end
         end
       end
       """},
      # try/rescue with fully unrelated body — baseline sanity.
      {"try/rescue body without any banned call",
       """
       defmodule X do
         def f(x) do
           try do
             Kernel.+(x, 1)
           rescue
             _ -> 0
           end
         end
       end
       """},
      # Repo.get! called OUTSIDE a try/rescue. The rule targets
      # try/rescue misuse specifically; a bare call is not in scope.
      {"Repo.get! call outside any try/rescue",
       """
       defmodule X do
         def f(id) do
           Repo.get!(User, id)
         end
       end
       """},
      # String.to_integer called OUTSIDE try/rescue.
      {"String.to_integer call outside any try/rescue",
       """
       defmodule X do
         def f(s) do
           String.to_integer(s)
         end
       end
       """},
      # Module with no try at all — must not flag.
      {"module with no try/rescue anywhere",
       """
       defmodule X do
         def f(x), do: x + 1
       end
       """},
      # try block whose body references a local function whose name
      # contains the trigger as a substring. The function name is not
      # a banned call but `Macro.to_string` renders it verbatim.
      {"try body calls a helper whose name contains 'to_integer' substring",
       """
       defmodule X do
         def f(s) do
           try do
             safe_to_integer_wrapper(s)
           rescue
             _ -> 0
           end
         end

         defp safe_to_integer_wrapper(s), do: Integer.parse(s)
       end
       """},
      # Repo.get! captured as a function reference (&Repo.get!/2). A
      # capture is not a call; the rule should not fire.
      {"Repo.get! used only as a function capture inside try",
       """
       defmodule X do
         def f do
           try do
             _ref = &Repo.get!/2
           rescue
             _ -> :ok
           end
         end
       end
       """}
    ]

    for {label, source} <- @pass_through_fixtures do
      @tag label: label
      test "passes: #{label}" do
        violations = walk!(unquote(source))

        refute has_rule?(violations, "try_rescue_flow_control"),
               "pass-through fixture was wrongly flagged by try_rescue_flow_control. " <>
                 "Violations: " <>
                 inspect(violations, limit: :infinity)
      end
    end

    test "pass-through fixtures outnumber drop fixtures" do
      # Sanity check on the N-K balance: pass-through must be strictly
      # larger than drop-side so silent-over-match bugs can't hide
      # behind a proportional test-count asymmetry.
      assert length(@pass_through_fixtures) > length(@drop_fixtures),
             "pass-through set should exceed drop-side set — got " <>
               "#{length(@pass_through_fixtures)} vs #{length(@drop_fixtures)}"
    end
  end
end
