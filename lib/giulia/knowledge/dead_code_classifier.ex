defmodule Giulia.Knowledge.DeadCodeClassifier do
  @moduledoc """
  Categorizes dead-code candidates into actionable vs irreducible buckets.

  After detection + exemption pass through `Metrics.dead_code_with_asts/3`,
  every surviving entry is classified so consumers (humans, agents, report
  templates) can distinguish "function with no caller — likely a real bug"
  from "function only reachable via a path the static analyzer cannot see —
  expected residual."

  Categories (precedence order — first match wins):

    1. `:test_only` — reference exists in some `*_test.exs` file under
       `<project>/test/`. Only callers are tests, which are intentionally
       excluded from the scan to avoid phantom-caller noise. The function
       is reachable from tests but not from production code.

    2. `:library_public_api` — the function is `:def` (public, not `defp`)
       and the project is library-shaped (its `mix.exs` `application/0`
       does not return a `:mod` entry). Public functions in a library are
       exported for downstream consumers the static analyzer cannot see.

    3. `:genuine` — none of the above match. Most likely a real dead
       function. Default category.

    4. `:uncategorized` — reserved. Unused by the current classifier but
       kept in the type union so future signals (variable-bound runtime
       dispatch, etc.) can land additively without breaking consumers.

  The classifier is a pure function over the entry and a `signals` map
  computed once per scan via `compute_signals/2`.

  > Note: prior versions had a `:template_pending` category as a
  > placeholder for the deferred `.heex` slice. That slice is now
  > built (`Giulia.Tools.TemplateReferences`) — template-referenced
  > functions are exempted from the dead-code list at detection time
  > rather than reaching the classifier. The category was retired in
  > v0.3.1.
  """

  alias Giulia.Context.ScanConfig
  alias Giulia.Tools.TestReferences

  @type category ::
          :test_only
          | :library_public_api
          | :genuine
          | :uncategorized

  @type entry :: %{
          required(:module) => String.t(),
          required(:name) => String.t(),
          required(:arity) => non_neg_integer(),
          required(:type) => atom(),
          optional(:file) => String.t(),
          optional(:line) => non_neg_integer()
        }

  @type signals :: %{
          required(:test_function_refs) => MapSet.t(),
          required(:application_mod?) => boolean()
        }

  @doc """
  Compute project-wide signals once for an entire `dead_code` run.

  Performs two I/O reads:
    - Walks `<project_path>/test/**/*_test.exs` for function references.
    - Reads `<project_path>/mix.exs` to detect `application/0 [mod: _]`.

  Pass the result to `classify/2` for every dead-code candidate.
  """
  @spec compute_signals(String.t(), map()) :: signals()
  def compute_signals(project_path, _all_asts) when is_binary(project_path) do
    %{
      test_function_refs: TestReferences.referenced_functions(project_path),
      application_mod?: ScanConfig.application_mod?(project_path)
    }
  end

  @doc """
  Classify a single dead-code entry against pre-computed project signals.
  See module doc for category precedence.
  """
  @spec classify(entry(), signals()) :: category()
  def classify(entry, signals) do
    cond do
      test_only?(entry, signals) -> :test_only
      library_public_api?(entry, signals) -> :library_public_api
      true -> :genuine
    end
  end

  @doc """
  Build a category-summary map for a list of classified entries. Returns
  `%{by_category: %{...}, irreducible: integer, actionable: integer}`.

  `irreducible` = `:test_only + :library_public_api`
  (entries the user is unlikely to want to act on; flagged for awareness).
  `actionable` = `:genuine + :uncategorized` (entries worth investigating).
  """
  @spec summarize([%{category: category()}]) :: %{
          by_category: %{category() => non_neg_integer()},
          irreducible: non_neg_integer(),
          actionable: non_neg_integer()
        }
  def summarize(classified_entries) when is_list(classified_entries) do
    by_category =
      Enum.reduce(
        classified_entries,
        %{
          genuine: 0,
          test_only: 0,
          library_public_api: 0,
          uncategorized: 0
        },
        fn %{category: c}, acc -> Map.update(acc, c, 1, &(&1 + 1)) end
      )

    irreducible = by_category.test_only + by_category.library_public_api
    actionable = by_category.genuine + by_category.uncategorized

    %{by_category: by_category, irreducible: irreducible, actionable: actionable}
  end

  # --- Predicates ---

  defp test_only?(%{module: m, name: n, arity: a}, %{test_function_refs: refs}) do
    MapSet.member?(refs, "#{m}.#{n}/#{a}")
  end

  defp library_public_api?(%{type: :def}, %{application_mod?: false}), do: true
  defp library_public_api?(_entry, _signals), do: false
end
