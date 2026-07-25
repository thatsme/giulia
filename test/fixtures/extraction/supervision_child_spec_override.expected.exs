[
  %{
    children: [
      %{
        conditional: false,
        key: "Fixture.Override.Plain",
        module: "Fixture.Override.Plain",
        order: 0,
        restart: :unknown
      },
      %{
        conditional: false,
        key: "Fixture.Override.Temporary",
        module: "Fixture.Override.Temporary",
        order: 1,
        restart: :temporary
      },
      %{
        conditional: false,
        key: "Fixture.Override.Mapped",
        module: "Fixture.Override.Mapped",
        order: 2,
        restart: :transient
      }
    ],
    children_unresolved: false,
    dynamic: false,
    key: "Fixture.Override.Supervisor",
    module: "Fixture.Override.Application",
    registered_name: "Fixture.Override.Supervisor",
    strategy: "one_for_one"
  }
]
