%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [
    %{
      arity: 1,
      complexity: 1,
      line: 19,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :valid?,
      type: :def
    },
    %{
      arity: 2,
      complexity: 0,
      line: 22,
      min_arity: 2,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :has_key?,
      type: :def
    },
    %{
      arity: 2,
      complexity: 0,
      line: 25,
      min_arity: 2,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :get!,
      type: :def
    },
    %{
      arity: 3,
      complexity: 0,
      line: 28,
      min_arity: 3,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :put!,
      type: :def
    },
    %{
      arity: 2,
      complexity: 0,
      line: 32,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :greet,
      type: :def
    },
    %{
      arity: 3,
      complexity: 0,
      line: 35,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :configure,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 41,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :can_proceed?,
      type: :defp
    },
    %{
      arity: 1,
      complexity: 0,
      line: 42,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :must_retry!,
      type: :defp
    },
    %{
      arity: 1,
      complexity: 0,
      line: 45,
      min_arity: 1,
      module: "Giulia.Fixtures.PredicateBangDefaultArgs",
      name: :delegated_check,
      type: :defdelegate
    }
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      line: 1,
      moduledoc:
        "Covers the two Step 1 extraction regressions:\n\n- Predicate functions (`?` suffix) and bang functions (`!` suffix)\n  were dropped by a regex that only accepted `\\\\w+` — `?` and `!`\n  are not word characters.\n- Default args produce multiple arities at extraction time\n  (`def foo(x, y \\\\\\\\ :default)` emits both `foo/1` and `foo/2`),\n  and earlier passes tracked only the max arity.\n\nBoth have regression tests; this fixture freezes the extraction\noutput so a future refactor that silently changes the arity list,\nreorders functions, or drops the `?`/`!` suffix gets surfaced as\na diff to the golden file.\n",
      name: "Giulia.Fixtures.PredicateBangDefaultArgs"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [
    %{arity: 1, function: :valid?, line: 18, spec: "valid?(any()) :: boolean()"},
    %{arity: 2, function: :has_key?, line: 21, spec: "has_key?(map(), atom()) :: boolean()"},
    %{arity: 2, function: :get!, line: 24, spec: "get!(map(), atom()) :: any()"},
    %{arity: 3, function: :put!, line: 27, spec: "put!(map(), atom(), any()) :: map()"},
    %{arity: 2, function: :greet, line: 31, spec: "greet(String.t(), String.t()) :: String.t()"}
  ],
  structs: [],
  types: []
}
