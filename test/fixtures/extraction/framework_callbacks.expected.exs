%{
  callbacks: [%{arity: 1, function: :custom_hook, line: 18, optional: true, spec: ""}],
  complexity: :normalized,
  docs: [],
  functions: [
    %{
      arity: 1,
      complexity: 0,
      line: 24,
      min_arity: 1,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :start_link,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 29,
      min_arity: 1,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :init,
      type: :def
    },
    %{
      arity: 3,
      complexity: 0,
      line: 34,
      min_arity: 3,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :handle_call,
      type: :def
    },
    %{
      arity: 2,
      complexity: 0,
      line: 43,
      min_arity: 2,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :handle_cast,
      type: :def
    },
    %{
      arity: 2,
      complexity: 0,
      line: 48,
      min_arity: 2,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :terminate,
      type: :def
    },
    %{
      arity: 1,
      complexity: 0,
      line: 52,
      min_arity: 1,
      module: "Giulia.Fixtures.FrameworkCallbacks",
      name: :plain_helper,
      type: :def
    }
  ],
  imports: [
    %{line: 14, module: "GenServer", type: :use},
    %{line: 16, module: "Giulia.Fixtures.SomeBehaviour", type: :use}
  ],
  line_count: :normalized,
  modules: [
    %{
      impl_for: nil,
      line: 1,
      moduledoc:
        "GenServer-style module exercising common framework wiring that\nextraction must see: `use GenServer`, `@impl true`, callback\nfunctions (`init/1`, `handle_call/3`, `handle_cast/2`,\n`terminate/2`), plus `@behaviour` + `@callback` declarations.\n\nHistorical regressions in this area: callbacks missed entirely\nbecause the extraction walked only top-level `def`; `@impl true`\non a `def` was sometimes attributed to the wrong function when\nsibling attributes were reordered.\n",
      name: "Giulia.Fixtures.FrameworkCallbacks"
    }
  ],
  optional_callbacks: [custom_hook: 1],
  path: "<fixture>",
  specs: [
    %{
      arity: 1,
      function: :start_link,
      line: 23,
      spec: "start_link(keyword()) :: GenServer.on_start()"
    }
  ],
  structs: [%{fields: [:counter, :name], line: 21, module: "Giulia.Fixtures.FrameworkCallbacks"}],
  types: []
}
