%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [
    %{
      arity: 1,
      complexity: 0,
      line: 8,
      min_arity: 1,
      module: "Giulia.Fixtures.MultiSerializable",
      name: :encode,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 14,
      min_arity: 1,
      module: "Giulia.Fixtures.MultiSerializable.Integer",
      name: :encode,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 18,
      min_arity: 1,
      module: "Giulia.Fixtures.MultiSerializable.Atom",
      name: :encode,
      type: :def
    }
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      impl_for: nil,
      line: 1,
      moduledoc:
        "Protocol with multi-type defimpl. Elixir compiles\n`defimpl X, for: [T1, T2, T3]` to three independent impl modules\nX.T1, X.T2, X.T3 — extraction must surface all three.\n",
      name: "Giulia.Fixtures.MultiSerializable"
    },
    %{
      impl_for: "Giulia.Fixtures.MultiSerializable",
      line: 11,
      moduledoc: "Numeric/string fast-path implementation.",
      name: "Giulia.Fixtures.MultiSerializable.Integer"
    },
    %{
      impl_for: "Giulia.Fixtures.MultiSerializable",
      line: 11,
      moduledoc: "Numeric/string fast-path implementation.",
      name: "Giulia.Fixtures.MultiSerializable.BitString"
    },
    %{
      impl_for: "Giulia.Fixtures.MultiSerializable",
      line: 11,
      moduledoc: "Numeric/string fast-path implementation.",
      name: "Giulia.Fixtures.MultiSerializable.Float"
    },
    %{
      impl_for: "Giulia.Fixtures.MultiSerializable",
      line: 17,
      moduledoc: nil,
      name: "Giulia.Fixtures.MultiSerializable.Atom"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [],
  structs: [],
  types: []
}
