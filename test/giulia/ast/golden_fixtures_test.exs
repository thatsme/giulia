defmodule Giulia.AST.GoldenFixturesTest do
  @moduledoc """
  Golden-file tests for `Processor.analyze/2` output.

  Each source file under `test/fixtures/extraction/<name>.ex` is paired
  with a frozen `<name>.expected.exs` term. The test parses the source,
  runs extraction, and diffs the result against the stored expected
  term. A mismatch is a regression the developer must either fix (if
  extraction drifted) or ratify by regenerating the golden file.

  **Regenerating golden files:** pass `GOLDEN_UPDATE=1`:

      GOLDEN_UPDATE=1 mix test test/giulia/ast/golden_fixtures_test.exs

  The test will write the current output to `<name>.expected.exs` and
  flunk so it never silently passes as green. Re-run without the env
  var to confirm the frozen output matches.

  **What the fixtures cover:**

  - `predicate_bang_default_args.ex` — `?`/`!` function names (the
    Step 1 `\\w+` regex bug) and default-arg arity cascades.
  - `moduledoc_variants.ex` — heredoc, single-line, `false`, missing,
    sigil_S forms of `@moduledoc` (commit 979e0ff contract).
  - `framework_callbacks.ex` — `use GenServer`, `@impl true`, callback
    functions, `@behaviour`, `@callback`, `@optional_callbacks`.

  The `:complexity` field and the `:path` field are normalized to stable
  values so the goldens don't churn on environment-dependent details.
  """
  use ExUnit.Case, async: true

  alias Giulia.AST.Processor

  @fixtures_dir Path.expand("../../fixtures/extraction", __DIR__)
  @update_golden System.get_env("GOLDEN_UPDATE") == "1"

  @fixture_cases [
    "predicate_bang_default_args",
    "moduledoc_variants",
    "framework_callbacks",
    "protocols_defimpl",
    "macros_guards",
    "nested_modules"
  ]

  for name <- @fixture_cases do
    @name name
    test "golden: #{name}" do
      source_path = Path.join(@fixtures_dir, "#{@name}.ex")
      expected_path = Path.join(@fixtures_dir, "#{@name}.expected.exs")

      source = File.read!(source_path)
      {:ok, ast, _} = Processor.parse(source)
      actual = Processor.analyze(ast, source) |> normalize()

      if @update_golden do
        formatted = Macro.to_string(quote do: unquote(Macro.escape(actual)))
        File.write!(expected_path, formatted <> "\n")

        flunk(
          "GOLDEN_UPDATE=1: wrote #{Path.relative_to_cwd(expected_path)}. " <>
            "Re-run without GOLDEN_UPDATE=1 to confirm."
        )
      end

      unless File.exists?(expected_path) do
        flunk(
          "Missing golden file: #{Path.relative_to_cwd(expected_path)}. " <>
            "Bootstrap it with `GOLDEN_UPDATE=1 mix test`."
        )
      end

      expected = load_expected(expected_path)

      assert actual == expected, """
      Golden fixture drift for #{@name}.

      Expected (from #{Path.relative_to_cwd(expected_path)}):
      #{inspect(expected, pretty: true, limit: :infinity)}

      Actual:
      #{inspect(actual, pretty: true, limit: :infinity)}

      If the new output is correct, regenerate with:
        GOLDEN_UPDATE=1 mix test test/giulia/ast/golden_fixtures_test.exs
      and review the diff in the commit.
      """
    end
  end

  # Strip fields that would cause churn without indicating real
  # extraction drift.
  defp normalize(%{} = file_info) do
    file_info
    |> Map.put(:path, "<fixture>")
    |> Map.put(:line_count, :normalized)
    |> Map.put(:complexity, :normalized)
  end

  defp load_expected(path) do
    {term, _bindings} = path |> File.read!() |> Code.eval_string()
    term
  end
end
