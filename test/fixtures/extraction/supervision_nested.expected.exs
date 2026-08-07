[
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Nested.Leaf.One",
        module: "Fixture.Nested.Leaf.One",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Nested.Leaf.Two",
        module: "Fixture.Nested.Leaf.Two",
        order: 1,
        restart: :unknown
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Nested.SubTree",
    module: "Fixture.Nested.SubTree",
    registered_name: "Fixture.Nested.SubTree",
    strategy: "one_for_all"
  },
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Nested.Telemetry",
        module: "Fixture.Nested.Telemetry",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Nested.SubTree",
        module: "Fixture.Nested.SubTree",
        order: 1,
        restart: :unknown
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Nested.Supervisor",
    module: "Fixture.Nested.Application",
    registered_name: "Fixture.Nested.Supervisor",
    strategy: "rest_for_one"
  }
]
