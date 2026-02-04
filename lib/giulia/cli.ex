defmodule Giulia.CLI do
  @moduledoc """
  The Thin Client - Entry Point for `giulia` Command.

  When compiled with Burrito/Bakeware, this becomes a system-wide binary.

  Flow:
  1. User types `giulia` (or `giulia /init`, `giulia /status`, etc.)
  2. CLI checks if daemon is running
  3. If not, starts the daemon
  4. Connects to daemon and sends request
  5. Displays response using Owl TUI

  The UX: Type `giulia` anywhere. It just works.
  """

  require Logger

  @commands %{
    "/init" => :init,
    "/status" => :status,
    "/projects" => :list_projects,
    "/help" => :help,
    "/stop" => :stop,
    "/version" => :version
  }

  @version Mix.Project.config()[:version] || "0.1.0"

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Main entry point for the CLI.
  Called by Burrito/Bakeware or `mix giulia`.
  """
  def main(args \\ []) do
    # Parse arguments
    {opts, rest, _} = OptionParser.parse(args, switches: [
      daemon: :boolean,
      verbose: :boolean,
      model: :string
    ])

    # If --daemon flag, we're being started as the daemon process
    if opts[:daemon] do
      start_as_daemon()
    else
      # Normal client mode
      run_client(rest, opts)
    end
  end

  # ============================================================================
  # Client Mode
  # ============================================================================

  defp run_client(args, opts) do
    # Ensure daemon is running
    case ensure_daemon() do
      :ok ->
        process_args(args, opts)

      {:error, reason} ->
        print_error("Failed to start daemon: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp process_args([], _opts) do
    # No args - start interactive mode
    interactive_mode()
  end

  defp process_args([cmd | rest], opts) when is_map_key(@commands, cmd) do
    # Known command
    handle_command(@commands[cmd], rest, opts)
  end

  defp process_args(args, opts) do
    # Treat entire args as a message
    message = Enum.join(args, " ")
    send_chat(message, opts)
  end

  # ============================================================================
  # Commands
  # ============================================================================

  defp handle_command(:init, args, _opts) do
    path = case args do
      [] -> File.cwd!()
      [p | _] -> Path.expand(p)
    end

    print_info("Initializing Giulia project at #{path}...")

    case rpc_call({:init, path, []}) do
      {:ok, _pid} ->
        print_success("Project initialized!")
        print_info("Created GIULIA.md - edit this to define your project's constitution.")
        print_info("Created .giulia/ folder for local state.")

      {:error, reason} ->
        print_error("Failed to initialize: #{inspect(reason)}")
    end
  end

  defp handle_command(:status, _args, _opts) do
    case rpc_call({:status}) do
      %{} = status ->
        print_status(status)

      {:error, reason} ->
        print_error("Failed to get status: #{inspect(reason)}")
    end
  end

  defp handle_command(:list_projects, _args, _opts) do
    case rpc_call({:list_projects}) do
      projects when is_list(projects) ->
        print_projects(projects)

      {:error, reason} ->
        print_error("Failed to list projects: #{inspect(reason)}")
    end
  end

  defp handle_command(:help, _args, _opts) do
    print_help()
  end

  defp handle_command(:stop, _args, _opts) do
    print_info("Stopping Giulia daemon...")
    rpc_call({:stop})
    print_success("Daemon stopped.")
  end

  defp handle_command(:version, _args, _opts) do
    IO.puts("Giulia v#{@version}")
  end

  # ============================================================================
  # Chat
  # ============================================================================

  defp send_chat(message, _opts) do
    pwd = File.cwd!()

    case rpc_call({:chat, pwd, message}) do
      {:ok, response} ->
        print_response(response)

      {:needs_init, path} ->
        print_warning("No GIULIA.md found in #{path}")
        print_info("Run `giulia /init` to initialize this project.")

      {:error, reason} ->
        print_error("Chat failed: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Interactive Mode
  # ============================================================================

  defp interactive_mode do
    pwd = File.cwd!()
    print_banner()

    # Check if project is initialized
    case rpc_call({:chat, pwd, "ping"}) do
      {:needs_init, path} ->
        print_warning("No GIULIA.md found.")
        if confirm?("Initialize Giulia in #{path}?") do
          handle_command(:init, [], [])
        end

      _ ->
        :ok
    end

    # Start REPL
    repl_loop(pwd)
  end

  defp repl_loop(pwd) do
    case IO.gets("giulia> ") do
      :eof ->
        print_info("\nGoodbye!")

      input ->
        input = String.trim(input)

        cond do
          input == "" ->
            repl_loop(pwd)

          input in ["/quit", "/exit", "/q"] ->
            print_info("Goodbye!")

          String.starts_with?(input, "/") ->
            [cmd | rest] = String.split(input, " ", parts: 2)
            args = if rest == [], do: [], else: String.split(hd(rest))
            handle_command(@commands[cmd] || :unknown, args, [])
            repl_loop(pwd)

          true ->
            send_chat(input, [])
            repl_loop(pwd)
        end
    end
  end

  # ============================================================================
  # Daemon Management
  # ============================================================================

  defp ensure_daemon do
    if Giulia.Daemon.running?() do
      case Giulia.Daemon.connect() do
        {:ok, _node} -> :ok
        {:error, _} -> start_daemon_process()
      end
    else
      start_daemon_process()
    end
  end

  defp start_daemon_process do
    print_info("Starting Giulia daemon...")

    # In development, we can start inline
    # In production (Burrito), we'd spawn a separate process
    case Application.ensure_all_started(:giulia) do
      {:ok, _} ->
        case Giulia.Daemon.start() do
          :ok ->
            print_success("Daemon started.")
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_as_daemon do
    # Running as the daemon process
    Logger.info("Starting as daemon process...")

    Application.ensure_all_started(:giulia)
    Giulia.Daemon.start()

    # Keep the process alive
    receive do
      :stop -> :ok
    end
  end

  defp rpc_call(request) do
    # In same-node mode (development), call directly
    # In distributed mode, use :rpc.call
    if Node.alive?() and Giulia.Daemon.running?() do
      node_name = :"giulia@localhost"
      :rpc.call(node_name, Giulia.Daemon, :handle_request, [request, self()])
    else
      # Same-node call
      Giulia.Daemon.handle_request(request, self())
    end
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_banner do
    IO.puts("""

    ╔═══════════════════════════════════════════════════╗
    ║                    GIULIA                          ║
    ║         AI Development Agent in Elixir             ║
    ╚═══════════════════════════════════════════════════╝

    Type your message or use /help for commands.
    """)
  end

  defp print_help do
    IO.puts("""

    Giulia Commands:

      /init [path]    Initialize a new project (creates GIULIA.md)
      /status         Show daemon status
      /projects       List active project contexts
      /help           Show this help
      /stop           Stop the daemon
      /quit           Exit interactive mode
      /version        Show version

    Usage:
      giulia                    Start interactive mode
      giulia "your message"     Send a one-shot message
      giulia /init              Initialize current directory

    """)
  end

  defp print_status(status) do
    IO.puts("""

    Giulia Daemon Status:

      Node:            #{status.node}
      Started:         #{status.started_at}
      Uptime:          #{format_uptime(status.uptime_seconds)}
      Active Projects: #{status.active_projects}
      Total Requests:  #{status.total_requests}

    """)
  end

  defp print_projects([]) do
    print_info("No active projects. Use `giulia /init` in a project directory.")
  end

  defp print_projects(projects) do
    IO.puts("\nActive Projects:\n")

    Enum.each(projects, fn p ->
      status = if p.alive, do: "[ACTIVE]", else: "[DEAD]"
      IO.puts("  #{status} #{p.path}")
      IO.puts("         Started: #{p.started_at}")
    end)

    IO.puts("")
  end

  defp print_response(response) do
    IO.puts("\n#{response}\n")
  end

  defp print_info(msg), do: IO.puts("\e[36m#{msg}\e[0m")
  defp print_success(msg), do: IO.puts("\e[32m✓ #{msg}\e[0m")
  defp print_warning(msg), do: IO.puts("\e[33m⚠ #{msg}\e[0m")
  defp print_error(msg), do: IO.puts("\e[31m✗ #{msg}\e[0m")

  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp confirm?(prompt) do
    response = IO.gets("#{prompt} [y/N] ") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end
end
