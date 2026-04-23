defmodule Giulia.Knowledge.ConventionsPropertyTest do
  @moduledoc """
  Property-based tests for `Conventions.walk_ast/3`.

  `walk_ast/3` runs eight per-node AST checks (try/rescue flow
  control, silent rescue, atom creation, process dict, unsupervised
  task, unless/else, append-in-reduce, if-not) plus a standalone
  pipe-chain pass. Example tests (`conventions_test.exs`) pin
  specific fixtures; these properties assert invariants across a
  generated space of valid Elixir source.

  Properties asserted:

    * **Determinism** — two walks of the same AST produce identical
      violation lists (same order, same content).
    * **Never crashes on valid Elixir** — `walk_ast/3` returns a
      list (possibly empty) for every parsed input; no exceptions
      propagate. Catches regressions where a new AST shape causes
      a pattern-match failure in one of the check clauses.
    * **Violations are well-formed** — every returned violation
      map has the required keys (`rule`, `message`, `category`,
      `severity`, `file`, `line`, `module`, `convention_ref`) with
      plausible types. Catches incomplete refactors to the
      violation struct.

  Source generation uses a template grammar that composes
  always-valid Elixir fragments. Parsing failures are filtered
  before the properties run — the goal is to exercise `walk_ast/3`
  across a wide AST space, not to test the parser.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Giulia.Knowledge.Conventions

  @required_violation_keys [
    :rule,
    :message,
    :category,
    :severity,
    :file,
    :line,
    :module,
    :convention_ref
  ]

  # Always-parseable Elixir fragments — each exercises a different
  # AST shape that walk_ast's checks inspect.
  @fragments [
    "def plain_def(x), do: x + 1",
    "def with_spec(x), do: x",
    "defp private_helper, do: :ok",
    """
    def tries_rescue(s) do
      try do
        Integer.parse(s)
      rescue
        _ -> :error
      end
    end
    """,
    """
    def silent_rescue_block(x) do
      try do
        x.foo
      rescue
        _ -> nil
      end
    end
    """,
    """
    def atom_create(s), do: String.to_atom(s)
    """,
    """
    def uses_process_dict do
      Process.put(:key, :value)
      Process.get(:key)
    end
    """,
    """
    def unsupervised(fun), do: Task.start(fun)
    """,
    """
    def unless_else(flag) do
      unless flag do
        :skip
      else
        :go
      end
    end
    """,
    """
    def append_reduce(items) do
      Enum.reduce(items, [], fn x, acc -> acc ++ [x] end)
    end
    """,
    """
    def if_not(x) do
      if not x, do: :falsy, else: :truthy
    end
    """,
    """
    def single_pipe(x), do: x |> Integer.to_string()
    """,
    """
    def chain_pipe(x), do: x |> to_string() |> String.upcase() |> String.trim()
    """
  ]

  # Generate a source string by picking a random non-empty subset
  # of fragments, stitching them into a synthetic module.
  defp module_source_gen do
    gen all fragments <-
              StreamData.list_of(
                StreamData.member_of(@fragments),
                min_length: 1,
                max_length: 6
              ),
            module_suffix <- StreamData.integer(0..999) do
      body = fragments |> Enum.uniq() |> Enum.join("\n\n  ")
      "defmodule Gen.Mod#{module_suffix} do\n  #{body}\nend\n"
    end
  end

  defp parse_or_nil(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast
      _ -> nil
    end
  end

  property "walk_ast/3 is deterministic — repeated walks produce the same violations" do
    check all source <- module_source_gen(), max_runs: 50 do
      ast = parse_or_nil(source)

      if ast do
        v1 = Conventions.walk_ast(ast, "gen.ex", "Gen")
        v2 = Conventions.walk_ast(ast, "gen.ex", "Gen")

        assert v1 == v2,
               "walk_ast drifted between calls on same AST.\n" <>
                 "Source: #{source}\nFirst: #{inspect(v1)}\nSecond: #{inspect(v2)}"
      end
    end
  end

  property "walk_ast/3 never crashes on generated valid Elixir" do
    check all source <- module_source_gen(), max_runs: 50 do
      ast = parse_or_nil(source)

      if ast do
        result = Conventions.walk_ast(ast, "gen.ex", "Gen")

        assert is_list(result),
               "walk_ast/3 must return a list — got #{inspect(result)} for source:\n#{source}"
      end
    end
  end

  property "every violation is a well-formed map with required keys" do
    check all source <- module_source_gen(), max_runs: 50 do
      ast = parse_or_nil(source)

      if ast do
        violations = Conventions.walk_ast(ast, "gen.ex", "Gen")

        for v <- violations do
          assert is_map(v), "violation is not a map: #{inspect(v)}"

          for key <- @required_violation_keys do
            assert Map.has_key?(v, key),
                   "violation missing required key #{inspect(key)}: #{inspect(v)}"
          end

          assert is_binary(v.rule), "rule must be a string: #{inspect(v)}"
          assert is_binary(v.message), "message must be a string: #{inspect(v)}"
          assert is_binary(v.category), "category must be a string: #{inspect(v)}"
          assert v.severity in ["error", "warning", "info"],
                 "severity must be error|warning|info: #{inspect(v)}"
          assert is_integer(v.line) and v.line >= 0, "line must be non-negative integer"
        end
      end
    end
  end
end
