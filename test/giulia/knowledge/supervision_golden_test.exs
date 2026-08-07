defmodule Giulia.Knowledge.SupervisionGoldenTest do
  @moduledoc """
  Golden-file tests for `Supervision.extract/1` output.

  Each source file under `test/fixtures/extraction/supervision_<shape>.ex` is
  paired with a frozen `<name>.expected.exs` term. The test extracts the
  supervision declarations and diffs them against the stored term. A mismatch is
  either a regression to fix or a deliberate change to ratify by regenerating.

  **Regenerating golden files:** pass `GOLDEN_UPDATE=1`:

      GOLDEN_UPDATE=1 mix test test/giulia/knowledge/supervision_golden_test.exs

  The test writes the current output and flunks, so a regeneration can never
  silently pass as green. Re-run without the env var to confirm.

  ## Why this is a separate module from `AST.GoldenFixturesTest`

  That module carries `@moduletag :golden_fixture_drift` and is excluded from
  every run: it freezes `Processor.analyze/2` output, which embeds AST metadata
  that churns across Elixir versions.

  This output has no such exposure — declarations are plain strings, atoms,
  integers and booleans, with no metadata — so these goldens are toolchain
  stable and run by default. Folding them into the other module would have
  silently disabled them, which for a fixture suite is worse than not having it.

  ## Shapes covered

  - `supervision_flat` — literal list, bare + `{mod, opts}` forms, `name:` ≠ module
  - `supervision_nested` — supervisor as both child and parent, via `Supervisor.init/2`
  - `supervision_conditional` — tiered `if`/`case`/`++` union with per-child conditionality
  - `supervision_dynamic` — two DynamicSupervisors sharing one module, kept distinct
  - `supervision_child_spec_override` — `child_spec/2` overrides and `%{start: {M,F,A}}` maps
  - `supervision_unresolvable` — the out-of-bounds cases, asserted as explicit gaps
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Supervision

  @fixtures_dir Path.expand("../../fixtures/extraction", __DIR__)
  @update_golden System.get_env("GOLDEN_UPDATE") == "1"

  @fixture_cases [
    "supervision_flat",
    "supervision_nested",
    "supervision_conditional",
    "supervision_dynamic",
    "supervision_child_spec_override",
    "supervision_unresolvable"
  ]

  for name <- @fixture_cases do
    @name name
    test "golden: #{name}" do
      source_path = Path.join(@fixtures_dir, "#{@name}.ex")
      expected_path = Path.join(@fixtures_dir, "#{@name}.expected.exs")

      actual = Supervision.extract(%{source_path => %{}})

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
      Supervision golden drift for #{@name}.

      Expected (from #{Path.relative_to_cwd(expected_path)}):
      #{inspect(expected, pretty: true, limit: :infinity)}

      Actual:
      #{inspect(actual, pretty: true, limit: :infinity)}

      If the new output is correct, regenerate with:
        GOLDEN_UPDATE=1 mix test test/giulia/knowledge/supervision_golden_test.exs
      and review the diff in the commit.
      """
    end
  end

  defp load_expected(path) do
    {term, _bindings} = path |> File.read!() |> Code.eval_string()
    term
  end
end
