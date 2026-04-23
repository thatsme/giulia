%{
  callbacks: [],
  complexity: :normalized,
  docs: [
    %{arity: 1, doc: "Encode a term into its serialized form.", function: :encode, line: 14},
    %{
      arity: 1,
      doc: "Estimate the byte size without fully encoding.",
      function: :byte_size_hint,
      line: 18
    }
  ],
  functions: [
    %{
      arity: 1,
      complexity: 0,
      line: 16,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable",
      name: :encode,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 20,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable",
      name: :byte_size_hint,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 26,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable.BitString",
      name: :encode,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 28,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable.BitString",
      name: :byte_size_hint,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 32,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable.Integer",
      name: :encode,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 34,
      min_arity: 1,
      module: "Giulia.Fixtures.Serializable.Integer",
      name: :byte_size_hint,
      type: :def
    }
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      line: 1,
      moduledoc:
        "Protocol declaration. Extraction should recognize this as a\ndistinct structure from `defmodule` — `defprotocol` expands to\na module but the callbacks are the contract, not plain functions.\n\nHistorical context: `defprotocol` used to surface as just another\nmodule with a few odd functions. Any future refactor that tightens\nprotocol handling will diff against this fixture.\n",
      name: "Giulia.Fixtures.Serializable"
    },
    %{
      line: 23,
      moduledoc: "BitString implementation of the Serializable protocol.",
      name: "Giulia.Fixtures.Serializable.BitString"
    },
    %{line: 31, moduledoc: nil, name: "Giulia.Fixtures.Serializable.Integer"}
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [
    %{arity: 1, function: :encode, line: 15, spec: "encode(t()) :: binary()"},
    %{
      arity: 1,
      function: :byte_size_hint,
      line: 19,
      spec: "byte_size_hint(t()) :: non_neg_integer()"
    }
  ],
  structs: [],
  types: [%{arity: 0, definition: "", line: 12, name: :t, visibility: :type}]
}
