%{
  callbacks: [],
  complexity: :normalized,
  docs: [
    %{
      arity: 1,
      doc: "Public macro that expands to a debug call.",
      function: :debug_call,
      line: 9
    },
    %{arity: 1, doc: "Public guard — usable in `when` clauses.", function: :is_tiny_int, line: 24}
  ],
  functions: [
    %{
      arity: 1,
      complexity: 0,
      line: 10,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :debug_call,
      type: :defmacro
    },
    %{
      arity: 1,
      complexity: 0,
      line: 17,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :internal_wrap,
      type: :defmacrop
    },
    %{
      arity: 1,
      complexity: 0,
      line: 25,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :is_tiny_int,
      type: :defguard
    },
    %{
      arity: 1,
      complexity: 0,
      line: 28,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :is_tuple_pair,
      type: :defguardp
    },
    %{
      arity: 1,
      complexity: 0,
      line: 32,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :classify,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 36,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :safe_parse,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 42,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :must_be_pair!,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 46,
      min_arity: 1,
      module: "Giulia.Fixtures.MacrosAndGuards",
      name: :trivial?,
      type: :def
    }
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      line: 1,
      moduledoc:
        "Covers `defmacro` / `defmacrop` / `defguard` / `defguardp` extraction\nagainst plain `def` / `defp`. Each has a distinct `type` atom in\n`function_info` and different downstream semantics (macros expand\nat compile time; guards have a restricted expression subset).\n",
      name: "Giulia.Fixtures.MacrosAndGuards"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [
    %{arity: 1, function: :classify, line: 31, spec: "classify(integer()) :: :tiny | :large"},
    %{arity: 1, function: :must_be_pair!, line: 41, spec: "must_be_pair!(tuple()) :: tuple()"},
    %{arity: 1, function: :trivial?, line: 45, spec: "trivial?(any()) :: boolean()"}
  ],
  structs: [],
  types: []
}
