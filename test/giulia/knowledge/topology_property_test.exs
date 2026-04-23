defmodule Giulia.Knowledge.TopologyPropertyTest do
  @moduledoc """
  Property-based tests for `Topology.fuzzy_score/2` and its helpers.

  The fuzzy-match path drives the "did you mean?" suggestion list
  returned by `impact_map/3` when the queried vertex is missing.
  Filter-accountability tests (`topology_test.exs`) already pin the
  per-tier scoring semantics for example pairs; these properties
  cover the wider input space and catch classes of regressions that
  example tests can miss — unintended scores outside the documented
  tier set, empty-string edge cases, and non-reflexive behavior.

  Properties asserted:

    * **Bounded output** — `fuzzy_score/2` only ever returns values
      from the documented tier set `{0, 10, 30, 50, 100}`. Any
      refactor that introduces a new tier or leaks an intermediate
      value gets caught.
    * **Empty-needle absorbent** — any empty needle produces 0,
      regardless of haystack. Pins the
      `String.contains?(_, "") == true` guard added in commit
      402263e.
    * **Reflexive 100** — a non-empty string matched against itself
      scores exactly 100 (the `haystack == needle` branch). Simple
      invariant but catches accidental normalization (e.g. a future
      `String.downcase` added to one side only).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Giulia.Knowledge.Topology

  @valid_scores [0, 10, 30, 50, 100]

  # Module-name-like strings: letters, digits, and dots — mirror
  # the inputs `impact_map/3` actually passes in (pre-downcased
  # dotted module names).
  defp module_string_gen do
    segment =
      StreamData.string(?a..?z, min_length: 1, max_length: 6)

    gen all parts <- StreamData.list_of(segment, min_length: 1, max_length: 4) do
      Enum.join(parts, ".")
    end
  end

  property "fuzzy_score/2 returns a value from the documented tier set" do
    check all haystack <- module_string_gen(),
              needle <- module_string_gen(),
              max_runs: 100 do
      score = Topology.fuzzy_score(haystack, needle)

      assert score in @valid_scores,
             "fuzzy_score(#{inspect(haystack)}, #{inspect(needle)}) produced " <>
               "#{score} — not in documented tier set #{inspect(@valid_scores)}"
    end
  end

  property "empty needle always scores 0 regardless of haystack" do
    check all haystack <- module_string_gen(), max_runs: 50 do
      assert Topology.fuzzy_score(haystack, "") == 0,
             "empty needle must score 0 (String.contains? trivially matches) — " <>
               "haystack: #{inspect(haystack)}"

      refute Topology.last_segment_match?(haystack, "")
      refute Topology.segments_overlap?(haystack, "")
    end
  end

  property "non-empty string matched against itself scores exactly 100" do
    check all string <- module_string_gen(), max_runs: 50 do
      # Guard against the generator producing "" (unlikely but
      # possible at the list boundary — list_of min_length: 1
      # plus segment min_length: 1 rules it out, but belt + braces).
      if string != "" do
        assert Topology.fuzzy_score(string, string) == 100,
               "reflexive match must score 100 — #{inspect(string)} " <>
                 "scored #{Topology.fuzzy_score(string, string)}"
      end
    end
  end
end
