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
    %{arity: 1, complexity: 0, line: 16, min_arity: 1, name: :encode, type: :def},
    %{arity: 1, complexity: 0, line: 20, min_arity: 1, name: :byte_size_hint, type: :def}
  ],
  imports: [],
  line_count: :normalized,
  modules: [],
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
