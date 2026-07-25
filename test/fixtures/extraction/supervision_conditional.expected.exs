[
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Conditional.Core",
        module: "Fixture.Conditional.Core",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: true,
        key: "Fixture.Conditional.Optional",
        module: "Fixture.Conditional.Optional",
        order: 1,
        restart: :unknown
      },
      %{
        conditional: true,
        key: "Fixture.Conditional.Primary",
        module: "Fixture.Conditional.Primary",
        order: 2,
        restart: :unknown
      },
      %{
        conditional: true,
        key: "Fixture.Conditional.Replica",
        module: "Fixture.Conditional.Replica",
        order: 3,
        restart: :unknown
      },
      %{
        conditional: true,
        key: "Fixture.Conditional.Endpoint",
        module: "Fixture.Conditional.Endpoint",
        order: 4,
        restart: :unknown
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Conditional.Supervisor",
    module: "Fixture.Conditional.Application",
    registered_name: "Fixture.Conditional.Supervisor",
    strategy: "one_for_one"
  }
]
