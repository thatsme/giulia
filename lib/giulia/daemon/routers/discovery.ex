defmodule Giulia.Daemon.Routers.Discovery do
  @moduledoc """
  Self-describing API discovery router.

  Aggregates `__skills__/0` from all domain sub-routers at request time,
  providing a single entry point for clients to discover available endpoints.

  Build 98: Discovery Engine — activates the @skill decorator pattern at runtime.
  """

  use Giulia.Daemon.SkillRouter

  @routers [
    __MODULE__,
    Giulia.Daemon.Routers.Approval,
    Giulia.Daemon.Routers.Transaction,
    Giulia.Daemon.Routers.Index,
    Giulia.Daemon.Routers.Search,
    Giulia.Daemon.Routers.Intelligence,
    Giulia.Daemon.Routers.Runtime,
    Giulia.Daemon.Routers.Knowledge,
    Giulia.Daemon.Routers.Monitor
  ]

  # -------------------------------------------------------------------
  # GET /api/discovery/skills — All skills, optional ?category=X filter
  # -------------------------------------------------------------------
  @skill %{
    intent: "List all available API skills with optional category filter",
    endpoint: "GET /api/discovery/skills",
    params: %{category: "optional — filter by category name"},
    returns: "JSON list of skill maps (intent, endpoint, params, returns, category)",
    category: "discovery"
  }
  get "/skills" do
    skills = all_skills()

    filtered =
      case conn.query_params["category"] do
        nil -> skills
        cat -> Enum.filter(skills, &(&1.category == cat))
      end

    send_json(conn, 200, %{skills: filtered, count: length(filtered)})
  end

  # -------------------------------------------------------------------
  # GET /api/discovery/categories — Category names with counts
  # -------------------------------------------------------------------
  @skill %{
    intent: "List all skill categories with endpoint counts",
    endpoint: "GET /api/discovery/categories",
    params: %{},
    returns: "JSON list of {category, count} objects",
    category: "discovery"
  }
  get "/categories" do
    categories =
      all_skills()
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, skills} -> %{category: cat, count: length(skills)} end)
      |> Enum.sort_by(& &1.category)

    send_json(conn, 200, %{categories: categories, total: length(categories)})
  end

  # -------------------------------------------------------------------
  # GET /api/discovery/search?q=TEXT — Case-insensitive intent search
  # -------------------------------------------------------------------
  @skill %{
    intent: "Search skills by keyword in intent description",
    endpoint: "GET /api/discovery/search",
    params: %{q: "required — search text (case-insensitive substring match on intent)"},
    returns: "JSON list of matching skill maps",
    category: "discovery"
  }
  get "/search" do
    case conn.query_params["q"] do
      nil ->
        send_json(conn, 400, %{error: "Missing required query parameter: q"})

      q ->
        q_lower = String.downcase(q)

        matches =
          all_skills()
          |> Enum.filter(fn skill ->
            String.contains?(String.downcase(skill.intent), q_lower)
          end)

        send_json(conn, 200, %{skills: matches, count: length(matches), query: q})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # -------------------------------------------------------------------
  # Private: aggregate skills from all routers
  # -------------------------------------------------------------------
  defp all_skills do
    Enum.flat_map(@routers, & &1.__skills__())
  end
end
