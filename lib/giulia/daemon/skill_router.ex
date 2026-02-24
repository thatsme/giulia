defmodule Giulia.Daemon.SkillRouter do
  @moduledoc """
  Macro module that provides the `use SkillRouter` convenience for sub-routers.

  Each sub-router gets:
  - `use Plug.Router` with standard plugs (match, fetch_query_params, JSON parser)
  - `import Giulia.Daemon.Helpers` for shared functions
  - `@skill` accumulator attribute for route metadata
  - `__skills__/0` function generated at compile time

  ## Usage

      defmodule MyRouter do
        use Giulia.Daemon.SkillRouter

        @skill %{
          intent: "Do something",
          endpoint: "GET /api/foo/bar",
          params: %{},
          returns: "JSON result",
          category: "foo"
        }
        get "/bar" do
          send_json(conn, 200, %{ok: true})
        end
      end

  After compilation, `MyRouter.__skills__()` returns the list of skill maps.
  """

  defmacro __using__(_opts) do
    quote do
      use Plug.Router
      plug :match
      plug :fetch_query_params

      plug Plug.Parsers,
        parsers: [:json],
        pass: ["application/json"],
        json_decoder: Jason

      plug :dispatch
      import Giulia.Daemon.Helpers
      Module.register_attribute(__MODULE__, :skill, accumulate: true)
      @before_compile Giulia.Daemon.SkillRouter
    end
  end

  defmacro __before_compile__(env) do
    skills = Module.get_attribute(env.module, :skill) |> Enum.reverse()

    quote do
      @doc "Returns all @skill annotations declared in this router."
      def __skills__, do: unquote(Macro.escape(skills))
    end
  end
end
