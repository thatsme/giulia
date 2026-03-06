defmodule Giulia.Client.Output do
  @moduledoc """
  Terminal output formatting — banner, help, status, colored messages.
  """

  alias Giulia.Client.HTTP

  @spec print_banner() :: :ok
  def print_banner do
    client_ver = Giulia.Version.short_version()

    server_ver = case HTTP.get("/health") do
      {:ok, %{"version" => v}} -> v
      _ -> "unknown"
    end

    model_name = detect_active_model()

    daemon_status = case HTTP.get("/api/index/status") do
      {:ok, %{"status" => status, "file_count" => count}} ->
        "UP (#{status}, #{count} files indexed)"
      _ ->
        "DOWN"
    end

    IO.puts("""

    +---------------------------------------------------------+
    |                       GIULIA                            |
    |            AI Development Agent (Docker Mode)           |
    +---------------------------------------------------------+
    | Client: #{String.pad_trailing(client_ver, 20)} Server: #{String.pad_trailing(server_ver, 15)}|
    | Model:  #{String.pad_trailing(model_name, 47)}|
    | Daemon: #{String.pad_trailing(daemon_status, 47)}|
    +---------------------------------------------------------+

    Connected to daemon. Type /help for commands.
    """)
  end

  defp detect_active_model do
    lm_url = System.get_env("GIULIA_LM_STUDIO_URL") || "http://127.0.0.1:1234"
    lm_url = String.trim_trailing(lm_url, "/")
    models_url = if String.contains?(lm_url, "/v1/"), do: String.replace(lm_url, ~r"/v1/.*", "/v1/models"), else: lm_url <> "/v1/models"

    case Req.get(models_url, receive_timeout: 3000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        body = if is_binary(body), do: Jason.decode!(body), else: body
        case body do
          %{"data" => [first | _]} ->
            first["id"] || "unknown"
          _ ->
            "unknown"
        end

      _ ->
        "not available"
    end
  rescue
    _ -> "not available"
  end

  @spec print_help() :: :ok
  def print_help do
    IO.puts("""

    Giulia Commands:

      /init [path]    Initialize a new project
      /status         Show daemon status
      /projects       List active project contexts
      /stop           Stop the Docker daemon
      /help           Show this help
      /quit           Exit interactive mode

    Multiline Input:
      \"\"\"               Start heredoc block (preserves blank lines)
      ...  your text    Type or paste freely
      \"\"\"               Close and send

      line ending \\    Continuation (joins with space)

    History Commands:
      /history        Show numbered command history
      !N              Replay command #N (e.g., !3)
      !!              Replay last command

    Index Commands (Pure Elixir - No LLM):
      /modules        List all indexed modules
      /functions      List all indexed functions
      /summary        Show project summary (for LLM context)
      /scan           Trigger re-indexing of current directory
      /indexstatus    Show indexer status
      /search <pat>   Search code for a pattern (no LLM)
      /integrity      Check behaviour-implementer consistency

    Transaction Commands:
      /transaction    Toggle transaction mode (stage writes in memory)
      /staged         Show currently staged files

    Debug Commands:
      /trace          Show last inference trace (what the model did)

    Usage:
      giulia                    Start interactive mode
      giulia "your message"     Send a one-shot message
      giulia /init              Initialize current directory
      giulia /modules           List modules without LLM

    Environment Variables:
      GIULIA_HOST_PROJECTS_PATH Host path for path mapping (e.g., "C:/Development/GitHub")

    """)
  end

  @spec print_status(map()) :: :ok
  def print_status(status) do
    IO.puts("""

    Giulia Daemon Status:

      Started:         #{status["started_at"] || "unknown"}
      Uptime:          #{format_uptime(status["uptime_seconds"] || 0)}
      Active Projects: #{status["active_projects"] || 0}
      Total Requests:  #{status["total_requests"] || 0}

    """)
  end

  @spec print_projects([map()] | term()) :: :ok
  def print_projects([]) do
    info("No active projects. Use `giulia /init` in a project directory.")
  end

  def print_projects(projects) when is_list(projects) do
    IO.puts("\nActive Projects:\n")

    Enum.each(projects, fn p ->
      path = if is_map(p), do: p["path"] || p[:path], else: p
      IO.puts("  - #{path}")
    end)

    IO.puts("")
  end

  def print_projects(_), do: info("No projects data.")

  defp format_uptime(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end
  defp format_uptime(_), do: "unknown"

  @spec info(String.t()) :: :ok
  def info(msg), do: IO.puts("\e[36m#{msg}\e[0m")
  @spec success(String.t()) :: :ok
  def success(msg), do: IO.puts("\e[32m+ #{msg}\e[0m")
  @spec warning(String.t()) :: :ok
  def warning(msg), do: IO.puts("\e[33m! #{msg}\e[0m")
  @spec error(String.t()) :: :ok
  def error(msg), do: IO.puts("\e[31m- #{msg}\e[0m")

  @spec confirm?(String.t()) :: boolean()
  def confirm?(prompt) do
    response = IO.gets("#{prompt} [y/N] ") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end
end
