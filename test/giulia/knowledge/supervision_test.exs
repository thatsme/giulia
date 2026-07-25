defmodule Giulia.Knowledge.SupervisionTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Supervision

  # Giulia's own application.ex is the acceptance fixture: five tiers, three of
  # them conditional, two DynamicSupervisors, and — critically — two separate
  # `Supervisor.start_link` call sites sharing one registered name.
  @application_ex "lib/giulia/application.ex"

  defp extract_application do
    Supervision.extract(%{@application_ex => %{}})
  end

  defp root(decls), do: Enum.find(decls, &(&1.key == "Giulia.Supervisor"))

  defp child_keys(decl), do: Enum.map(decl.children, & &1.key)

  describe "extract/1 on Giulia's own application.ex" do
    test "finds the root supervisor by registered name, not by module" do
      # `Giulia.Supervisor` has no defmodule anywhere in the codebase. Keying by
      # module would leave the tree with no root at all.
      assert root = root(extract_application())
      assert root.registered_name == "Giulia.Supervisor"
      assert root.strategy == "one_for_one"
    end

    test "unions children across BOTH start_link call sites" do
      # The client_mode? branch starts `Supervisor.start_link([], ...)` under the
      # SAME name as the daemon branch. A pass that takes the first match, or
      # merges without union semantics, returns an empty tree — and would pass
      # every positive assertion written about it. This asserts that failure
      # mode by name rather than merely avoiding it.
      root = root(extract_application())

      refute root.children == [],
             "empty tree: the client_mode? branch won the merge instead of being unioned"

      refute root.children_unresolved,
             "root children must resolve — bindings are single-assignment ++ chains"

      keys = child_keys(root)

      # Tier 1 (unconditional), tier 3 (conditional on role), tier 5 (env-gated)
      assert "Giulia.Context.Store" in keys
      assert "Giulia.Inference.Trace" in keys
      assert "Giulia.MCP.Server" in keys
    end

    test "keys named children by registered name, not module" do
      # {Registry, name: Giulia.Registry} and {Task.Supervisor, name:
      # Giulia.TaskSupervisor} have the same identity problem as the
      # supervisors: the module is external and shared.
      keys = extract_application() |> root() |> child_keys()

      assert "Giulia.Registry" in keys
      assert "Giulia.TaskSupervisor" in keys
    end

    test "keeps the two DynamicSupervisors distinct" do
      # Both are `{DynamicSupervisor, name: X}`. Keying by module collapses them.
      keys = extract_application() |> root() |> child_keys()

      assert "Giulia.Provider.Supervisor" in keys
      assert "Giulia.Core.ProjectSupervisor" in keys
    end

    test "flags conditional-tier children and leaves unconditional ones clean" do
      root = root(extract_application())
      by_key = Map.new(root.children, &{&1.key, &1})

      # Tier 1 is unconditional in every branch.
      refute by_key["Giulia.Context.Store"].conditional

      # Tier 3 is skipped entirely when GIULIA_ROLE=monitor.
      assert by_key["Giulia.Inference.Trace"].conditional

      # Bandit is appended only when Mix.env() != :test.
      assert by_key["Bandit"].conditional
    end
  end

  describe "bounded binding resolution" do
    test "resolves literal lists, ++ chains and single-assignment vars" do
      source = """
      defmodule Demo.App do
        def start(_type, _args) do
          base = [Demo.A, {Demo.B, name: Demo.Named}]
          extra = [Demo.C]
          Supervisor.start_link(base ++ extra, strategy: :one_for_one, name: Demo.Sup)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Sup"))

      refute decl.children_unresolved
      assert Enum.map(decl.children, & &1.key) == ["Demo.A", "Demo.Named", "Demo.C"]
      refute Enum.any?(decl.children, & &1.conditional)
    end

    test "name: __MODULE__ resolves to the enclosing module, not the sentinel" do
      # Regression: `__MODULE__` parses as `{:__MODULE__, meta, ctx}`, which
      # matched the variable clause in resolve_expr/3, found no binding, and
      # returned the `:unresolved` sentinel — rendered as a process literally
      # named ":unresolved". Every fixture here used an alias (`name: Demo.Sup`)
      # and so did Giulia's own application.ex, so the entire suite missed the
      # most common supervisor-naming idiom in Elixir. Caught by running
      # against Plug.
      source = """
      defmodule Demo.App do
        use Application

        def start(_type, _args) do
          children = [Demo.Worker]
          Supervisor.start_link(children, name: __MODULE__, strategy: :one_for_one)
        end
      end
      """

      decls = extract_source(source)

      refute Enum.any?(decls, &(&1.key == ":unresolved")),
             "the resolution sentinel leaked into a vertex key"

      assert decl = Enum.find(decls, &(&1.key == "Demo.App"))
      assert decl.registered_name == "Demo.App"
      assert Enum.map(decl.children, & &1.key) == ["Demo.Worker"]
    end

    test "refuses to guess at function-built child lists" do
      source = """
      defmodule Demo.App do
        def start(_type, _args) do
          Supervisor.start_link(build_children(), strategy: :one_for_one, name: Demo.Sup)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Sup"))

      assert decl.children_unresolved
      assert decl.children == []
    end

    test "does not cross function boundaries when resolving a variable" do
      # `children` is bound in another function. Resolving it would require
      # cross-function tracing, which is explicitly out of bounds.
      source = """
      defmodule Demo.App do
        def children_list do
          children = [Demo.A]
          children
        end

        def start(_type, _args) do
          Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Sup)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Sup"))

      assert decl.children_unresolved
    end

    test "drops multiply-assigned variables rather than picking one" do
      source = """
      defmodule Demo.App do
        def start(_type, _args) do
          children = [Demo.A]
          children = [Demo.B]
          Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Sup)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Sup"))

      assert decl.children_unresolved
    end
  end

  describe "child spec shapes" do
    test "handles bare alias, {mod, opts}, spec map and child_spec override" do
      source = """
      defmodule Demo.App do
        def start(_type, _args) do
          children = [
            Demo.Bare,
            {Demo.Tupled, name: Demo.Registered},
            %{id: Demo.Mapped, start: {Demo.Mapped, :start_link, []}, restart: :transient},
            Supervisor.child_spec({Demo.Spec, []}, restart: :temporary)
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Sup)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Sup"))
      by_key = Map.new(decl.children, &{&1.key, &1})

      assert by_key["Demo.Bare"].module == "Demo.Bare"
      assert by_key["Demo.Registered"].module == "Demo.Tupled"
      assert by_key["Demo.Mapped"].restart == :transient
      assert by_key["Demo.Spec"].restart == :temporary
    end

    test "marks DynamicSupervisor dynamic with no children" do
      source = """
      defmodule Demo.App do
        def start(_type, _args) do
          DynamicSupervisor.start_link(strategy: :one_for_one, name: Demo.Dyn)
        end
      end
      """

      decl = source |> extract_source() |> Enum.find(&(&1.key == "Demo.Dyn"))

      assert decl.dynamic
      assert decl.children == []
      refute decl.children_unresolved
    end
  end

  # Write the source to a temp file — extraction is file-path driven, matching
  # how Builder Pass 6 reaches the full AST.
  defp extract_source(source) do
    path = Path.join(System.tmp_dir!(), "supervision_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      Supervision.extract(%{path => %{}})
    after
      File.rm(path)
    end
  end
end
