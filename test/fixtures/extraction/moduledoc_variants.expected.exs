%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [%{arity: 0, complexity: 0, line: 9, min_arity: 0, name: :run, type: :def}],
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
