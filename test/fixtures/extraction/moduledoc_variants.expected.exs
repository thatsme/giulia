%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [
    %{
      arity: 0,
      complexity: 0,
      line: 9,
      min_arity: 0,
      module: "Giulia.Fixtures.ModuledocHeredoc",
      name: :run,
      type: :def
    },
    %{
      arity: 0,
      complexity: 0,
      line: 15,
      min_arity: 0,
      module: "Giulia.Fixtures.ModuledocSingleLine",
      name: :run,
      type: :def
    },
    %{
      arity: 0,
      complexity: 0,
      line: 24,
      min_arity: 0,
      module: "Giulia.Fixtures.ModuledocFalse",
      name: :run,
      type: :def
    },
    %{
      arity: 0,
      complexity: 0,
      line: 29,
      min_arity: 0,
      module: "Giulia.Fixtures.ModuledocMissing",
      name: :run,
      type: :def
    },
    %{
      arity: 0,
      complexity: 0,
      line: 37,
      min_arity: 0,
      module: "Giulia.Fixtures.ModuledocSigilS",
      name: :run,
      type: :def
    }
  ],
  imports: [],
  line_count: :normalized,
  modules: [
    %{
      line: 1,
      moduledoc:
        "Heredoc form.\n\nMulti-line content with embedded `quoted tokens` and **markdown**.\nThe extractor must preserve the string content verbatim.\n",
      name: "Giulia.Fixtures.ModuledocHeredoc"
    },
    %{
      line: 12,
      moduledoc: "Single-line string form.",
      name: "Giulia.Fixtures.ModuledocSingleLine"
    },
    %{line: 18, moduledoc: false, name: "Giulia.Fixtures.ModuledocFalse"},
    %{line: 27, moduledoc: nil, name: "Giulia.Fixtures.ModuledocMissing"},
    %{
      line: 32,
      moduledoc: "Sigil_S form — no interpolation, preserves \#{literals}.\n",
      name: "Giulia.Fixtures.ModuledocSigilS"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [],
  structs: [],
  types: []
}
