%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [
    %{arity: 0, complexity: 0, line: 15, min_arity: 0, name: :outer_only_fn, type: :def},
    %{arity: 0, complexity: 0, line: 20, min_arity: 0, name: :inner_only_fn, type: :def},
    %{arity: 0, complexity: 0, line: 22, min_arity: 0, name: :shared_name, type: :def},
    %{arity: 0, complexity: 0, line: 38, min_arity: 0, name: :deep, type: :def}
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      line: 1,
      moduledoc:
        "Module with a nested inner module. Tests whether extraction\nsurfaces `Outer.Inner` as a distinct module entry (with its own\nfunctions) or flattens it into the outer's extraction.\n\nHistorical note: the extractor currently treats each\n`defmodule` block as a top-level module, so `Outer.Inner` should\nappear as a separate module entry alongside `Outer`. Functions\ndefined INSIDE `Outer.Inner` should NOT be attributed to the\nouter module. This fixture pins the current behaviour so any\nrefactor that nests differently produces a visible diff.\n",
      name: "Giulia.Fixtures.Outer"
    },
    %{line: 17, moduledoc: "Inner module nested inside Outer.", name: "Inner"},
    %{line: 33, moduledoc: nil, name: "Giulia.Fixtures.Triple"},
    %{line: 34, moduledoc: nil, name: "Mid"},
    %{
      line: 35,
      moduledoc: "Leaf at three nesting levels — pins triple-nested extraction.",
      name: "Leaf"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [],
  structs: [],
  types: []
}
