[
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Flat.Cache",
        module: "Fixture.Flat.Cache",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Flat.Worker",
        module: "Fixture.Flat.Worker",
        order: 1,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Flat.Registry",
        module: "Registry",
        order: 2,
        restart: :unknown
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Flat.Supervisor",
    module: "Fixture.Flat.Application",
    registered_name: "Fixture.Flat.Supervisor",
    strategy: "one_for_one"
  }
]
