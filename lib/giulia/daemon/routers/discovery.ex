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

  # -------------------------------------------------------------------
  # GET /api/discovery/report_rules — Report generation rules location + content
  # -------------------------------------------------------------------
  @skill %{
    intent: "Get REPORT_RULES.md path and content for analysis report generation",
    endpoint: "GET /api/discovery/report_rules",
    params: %{},
    returns: "JSON with host_path (for Claude Code to read) and content (full rules text)",
    category: "discovery"
  }
  get "/report_rules" do
    # System-wide Claude Code config path on the host
    host_home = System.get_env("GIULIA_HOST_HOME") || infer_host_home()
    host_path = Path.join([host_home, ".claude", "REPORT_RULES.md"])

    # Read from the project docs/ copy inside the container (always available)
    container_path = "/projects/Giulia/docs/REPORT_RULES.md"

    content =
      case File.read(container_path) do
        {:ok, text} -> text
        _ -> nil
      end

    send_json(conn, 200, %{
      host_path: host_path,
      container_path: container_path,
      content: content,
      hint: "Read host_path with your file tools. Content included as fallback."
    })
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------
  defp all_skills do
    Enum.flat_map(@routers, & &1.__skills__())
  end

  defp infer_host_home do
    # Derive from GIULIA_HOST_PROJECTS_PATH (e.g. "D:/Development/GitHub" → "D:/Users/...")
    # Fall back to a sensible default based on OS conventions
    case System.get_env("GIULIA_HOST_PROJECTS_PATH") do
      nil -> "~"
      path ->
        # Windows: "D:/Development/GitHub" → drive letter, then look for Users
        # Best effort: use USERPROFILE-style path
        case Regex.run(~r/^([A-Za-z]:)/, path) do
          [_, drive] -> drive <> "/Users/" <> (System.get_env("GIULIA_HOST_USER") || "user")
          _ -> "~"
        end
    end
  end
end
