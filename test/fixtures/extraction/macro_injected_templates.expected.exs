%{
  callbacks: [],
  complexity: :normalized,
  docs: [],
  functions: [
    %{
      arity: 1,
      complexity: 0,
      line: 11,
      min_arity: 1,
      module: "Giulia.Fixtures.UseHost",
      name: :__using__,
      type: :defmacro
    },
    %{
      arity: 1,
      complexity: 0,
      line: 21,
      min_arity: 1,
      module: "Giulia.Fixtures.UseHost",
      name: :real_helper,
      type: :def
    },
    %{
      arity: 0,
      complexity: 0,
      line: 29,
      min_arity: 0,
      module: "Giulia.Fixtures.UseConsumer",
      name: :actual_def,
      type: :def
    }
  ],
  imports: [%{line: 27, module: "Giulia.Fixtures.UseHost", type: :use}],
  line_count: :normalized,
  modules: [
    %{
      impl_for: nil,
      line: 1,
      moduledoc:
        "Defines a `use` macro that injects template functions into consumers.\nThe `def adapter/0` and `def changeset/1` declarations inside the\n`quote do ... end` block are templates — they will be created in\nmodules that do `use Giulia.Fixtures.UseHost`. Slice E3 says they\nmust NOT be attributed to UseHost itself, otherwise the surface\narea is overstated and the templates look like dead code.\n",
      name: "Giulia.Fixtures.UseHost"
    },
    %{
      impl_for: nil,
      line: 24,
      moduledoc: "Consumer of UseHost. Has its own `actual_def/0`.",
      name: "Giulia.Fixtures.UseConsumer"
    }
  ],
  optional_callbacks: [],
  path: "<fixture>",
  specs: [],
  structs: [],
  types: []
}
