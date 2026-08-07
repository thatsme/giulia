[
  %{
    children: [],
    children_unresolved: false,
    dynamic: true,
    key: "Fixture.Dynamic.SessionSup",
    module: "DynamicSupervisor",
    registered_name: "Fixture.Dynamic.SessionSup",
    strategy: nil
  },
  %{
    children: [],
    children_unresolved: false,
    dynamic: true,
    key: "Fixture.Dynamic.Standalone",
    module: "Fixture.Dynamic.Standalone",
    registered_name: "Fixture.Dynamic.Standalone",
    strategy: "one_for_one"
  },
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Dynamic.WorkerSup",
        module: "DynamicSupervisor",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Dynamic.SessionSup",
        module: "DynamicSupervisor",
        order: 1,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Dynamic.Manager",
        module: "Fixture.Dynamic.Manager",
        order: 2,
        restart: :unknown
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Dynamic.Supervisor",
    module: "Fixture.Dynamic.Application",
    registered_name: "Fixture.Dynamic.Supervisor",
    strategy: "one_for_one"
  },
  %{
    children: [],
    children_unresolved: false,
    dynamic: true,
    key: "Fixture.Dynamic.WorkerSup",
    module: "DynamicSupervisor",
    registered_name: "Fixture.Dynamic.WorkerSup",
    strategy: nil
  }
]
