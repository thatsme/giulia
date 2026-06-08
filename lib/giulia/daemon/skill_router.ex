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

  ## The `@skill` contract

  The `@skill` map IS the per-endpoint API contract, and it lives here —
  next to the route that implements it — so it cannot drift from the code
  the way a hand-maintained external doc (SKILL.md) does. Two consumers read
  it: the Discovery API (`/api/discovery/*`) serves the maps verbatim, and
  `Giulia.MCP.ToolSchema` derives MCP tool definitions from them.

  ### Fields

    * `intent` — one-line description (also the MCP tool `description`).
    * `endpoint` — `"<METHOD> /api/<path>"`. Drives the MCP tool name.
    * `returns` — prose summary of the success body. The precise response
      shape is NOT duplicated here; it lives in the `@spec` of the dispatched
      handler. Do not hand-maintain a response-shape map — that just relocates
      drift from SKILL.md to `@skill`-vs-`@spec`.
    * `category` — owning category (matches the router prefix).
    * `notes` — OPTIONAL freeform prose for preconditions, error/status codes
      (e.g. 422 conditions), and runtime caveats ("requires EmbeddingServing",
      "L3 UNAVAILABLE if ArcadeDB down"). Deliberately unstructured — modelling
      these would mean modelling dependencies, which discovery does not need.

  ### `params` — structured maps

  Each param value is a map describing one argument:

      params: %{
        path: %{required: true, in: "query", doc: "Absolute project path"},
        relevance: %{
          required: false,
          in: "query",
          values: ~w(high medium all),
          default: "all",
          doc: "high -> genuine only; medium -> genuine + uncategorized; all -> unfiltered"
        }
      }

  Keys: `required` (bool), `in` (`"query"` | `"body"`), and optional `values`
  (allowed enum), `default`, `format` (e.g. `"Module.func/arity"`), `doc`.

  **Default convention — `default:` carries the WIRE representation (a string),
  never the typed value.** Every param here is a query/body text argument
  (`?max=20` arrives as `"20"` and the handler `Integer.parse`s it), and the
  MCP schema types all params as `string`. So `default: "20"` is type-consistent
  with the emitted `string` type; a bare `20` would be a type mismatch. Do not
  introduce numeric `default:` values without first adding a `type:` key the MCP
  layer can emit.

  **MCP boundary caveat (anubis_mcp 1.0.0 / peri 0.6.2):** `values` is emitted
  to the MCP JSON Schema as `enum`, but `default` is NOT — the converter discards
  it (`convert_type({type, {:default, _}}), do: convert_type(type)`). `ToolSchema`
  folds `default` into the emitted `description` so MCP clients still see it.
  Discovery serves `default` structurally (pure Jason, never touches peri), so the
  structured value is preserved there regardless.
  """

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use Plug.Router
      plug(:match)
      plug(:fetch_query_params)

      plug(Plug.Parsers,
        parsers: [:json],
        pass: ["application/json"],
        json_decoder: Jason
      )

      plug(:dispatch)
      import Giulia.Daemon.Helpers
      Module.register_attribute(__MODULE__, :skill, accumulate: true)
      @before_compile Giulia.Daemon.SkillRouter
    end
  end

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    skills = Enum.reverse(Module.get_attribute(env.module, :skill))

    quote do
      @doc "Returns all @skill annotations declared in this router."
      @spec __skills__() :: [map()]
      def __skills__, do: unquote(Macro.escape(skills))
    end
  end
end
