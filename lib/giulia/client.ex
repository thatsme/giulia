defmodule Giulia.Client do
  @moduledoc """
  The Thin Client - Connects to Giulia Daemon via HTTP.

  Simple, reliable, works across Docker boundaries.
  No EPMD drama, no bi-directional handshakes.
  """

  @daemon_url "http://localhost:4000"
  @docker_image "giulia/core:latest"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Main entry point for the thin client.
  """
  def main(args \\ []) do
    case ensure_daemon_running() do
      :ok ->
        process_command(args)

      {:error, reason} ->
        error("Failed to start daemon: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Send a chat message to the daemon.
  """
  def chat(message, opts \\ []) do
    path = Keyword.get(opts, :path, get_working_directory())

    post("/api/command", %{message: message, path: path})
  end

  @doc """
  Initialize a project via the daemon.
  """
  def init_project(path \\ nil, _opts \\ []) do
    host_path = path || get_working_directory()

    post("/api/init", %{path: host_path})
  end

  # Get the real working directory (where user launched from, not where mix runs)
  defp get_working_directory do
    # GIULIA_CLIENT_CWD is set by giulia.bat to the original directory
    case System.get_env("GIULIA_CLIENT_CWD") do
      nil -> File.cwd!()
      "" -> File.cwd!()
      dir -> dir
    end
  end

  @doc """
  Get daemon status.
  """
  def status do
    get("/api/status")
  end

  @doc """
  List active projects.
  """
  def list_projects do
    get("/api/projects")
  end

  # ============================================================================
  # Command Processing
  # ============================================================================

  defp process_command([]) do
    # Interactive mode
    interactive_mode()
  end

  defp process_command(["/init" | rest]) do
    path = List.first(rest) || get_working_directory()

    case init_project(path) do
      {:ok, %{"status" => "initialized"}} ->
        success("Project initialized at #{path}")
        info("Created GIULIA.md - edit this to define your project's constitution.")

      {:ok, %{"error" => reason}} ->
        error("Failed to initialize: #{reason}")

      {:error, reason} ->
        error("Failed to initialize: #{inspect(reason)}")
    end
  end

  defp process_command(["/status"]) do
    case status() do
      {:ok, status} ->
        print_status(status)

      {:error, reason} ->
        error("Failed to get status: #{inspect(reason)}")
    end
  end

  defp process_command(["/projects"]) do
    case list_projects() do
      {:ok, %{"projects" => projects}} ->
        print_projects(projects)

      {:error, reason} ->
        error("Failed to list projects: #{inspect(reason)}")
    end
  end

  defp process_command(["/stop"]) do
    info("Stopping Giulia daemon...")
    stop_docker_daemon()
    success("Daemon stopped.")
  end

  defp process_command(["/help"]) do
    print_help()
  end

  defp process_command(["/modules"]) do
    case get("/api/index/modules") do
      {:ok, %{"modules" => modules, "count" => count}} ->
        IO.puts("\nIndexed Modules (#{count}):\n")
        Enum.each(modules, fn mod ->
          IO.puts("  #{mod["name"]}")
          IO.puts("    File: #{mod["file"]}:#{mod["line"]}")
        end)
        IO.puts("")

      {:error, reason} ->
        error("Failed to get modules: #{inspect(reason)}")
    end
  end

  defp process_command(["/functions"]) do
    case get("/api/index/functions") do
      {:ok, %{"functions" => functions, "count" => count}} ->
        IO.puts("\nIndexed Functions (#{count}):\n")
        functions
        |> Enum.group_by(& &1["module"])
        |> Enum.each(fn {module, funcs} ->
          IO.puts("  #{module}:")
          Enum.each(funcs, fn f ->
            visibility = if f["type"] == "def", do: "pub", else: "priv"
            IO.puts("    #{f["name"]}/#{f["arity"]} [#{visibility}]")
          end)
        end)
        IO.puts("")

      {:error, reason} ->
        error("Failed to get functions: #{inspect(reason)}")
    end
  end

  defp process_command(["/summary"]) do
    case get("/api/index/summary") do
      {:ok, %{"summary" => summary}} ->
        IO.puts("\n#{summary}")

      {:error, reason} ->
        error("Failed to get summary: #{inspect(reason)}")
    end
  end

  defp process_command(["/scan"]) do
    host_path = get_working_directory()

    case post("/api/index/scan", %{path: host_path}) do
      {:ok, %{"status" => "scanning", "path" => path}} ->
        info("Started scanning: #{path}")
        info("Use /indexstatus to check progress.")

      {:error, reason} ->
        error("Failed to start scan: #{inspect(reason)}")
    end
  end

  defp process_command(["/indexstatus"]) do
    case get("/api/index/status") do
      {:ok, status} ->
        IO.puts("\nIndexer Status:")
        IO.puts("  Status: #{status["status"]}")
        IO.puts("  Project: #{status["project_path"] || "none"}")
        IO.puts("  Files: #{status["file_count"]}")
        if status["last_scan"], do: IO.puts("  Last Scan: #{status["last_scan"]}")
        IO.puts("")

      {:error, reason} ->
        error("Failed to get indexer status: #{inspect(reason)}")
    end
  end

  defp process_command(["/trace"]) do
    case get("/api/agent/last_trace") do
      {:ok, %{"trace" => nil}} ->
        info("No inference trace available yet.")

      {:ok, %{"trace" => trace}} ->
        IO.puts("\n=== LAST INFERENCE TRACE ===")
        IO.puts("Task: #{trace["task"]}")
        IO.puts("Status: #{trace["status"]}")
        IO.puts("Iterations: #{trace["iteration"]}/#{trace["max_iterations"]}")
        IO.puts("Provider: #{trace["provider"]}")
        IO.puts("Failures: #{trace["consecutive_failures"]}")

        if trace["action_history"] && trace["action_history"] != [] do
          IO.puts("\nAction History:")
          Enum.each(trace["action_history"], fn action ->
            result_str = case action["result"] do
              {:ok, _} -> "OK"
              ["ok", _] -> "OK"
              {:error, r} -> "ERROR: #{inspect(r)}"
              ["error", r] -> "ERROR: #{inspect(r)}"
              other -> inspect(other)
            end
            IO.puts("  - #{action["tool"]}(#{inspect(action["params"])}) -> #{result_str}")
          end)
        end

        if trace["recent_errors"] && trace["recent_errors"] != [] do
          IO.puts("\nRecent Errors:")
          Enum.each(trace["recent_errors"], fn err ->
            IO.puts("  - #{inspect(err)}")
          end)
        end

        IO.puts("")

      {:error, reason} ->
        error("Failed to get trace: #{inspect(reason)}")
    end
  end

  defp process_command(args) do
    # Treat as chat message
    message = Enum.join(args, " ")
    host_path = get_working_directory()
    execute_input(message, host_path)
  end

  # ============================================================================
  # Interactive Mode
  # ============================================================================

  defp interactive_mode do
    print_banner()
    host_path = get_working_directory()

    # Check if project is initialized
    case post("/api/command", %{message: "ping", path: host_path}) do
      {:ok, %{"status" => "needs_init"}} ->
        warning("No GIULIA.md found.")

        if confirm?("Initialize Giulia in current directory?") do
          init_project(host_path)
          success("Initialized!")
        end

      _ ->
        :ok
    end

    repl_loop(host_path)
  end

  # Simple readline with history using raw terminal mode
  defp repl_loop(host_path), do: repl_loop(host_path, [], 0, "")

  defp repl_loop(host_path, history, hist_pos, buffer) do
    IO.write("giulia> #{buffer}")

    input = read_line_with_history(buffer, history, hist_pos)

    case input do
      :eof ->
        info("\nGoodbye!")

      {:history, new_pos, new_buffer} ->
        # Clear line and redraw
        IO.write("\r\e[K")
        repl_loop(host_path, history, new_pos, new_buffer)

      line ->
        line = String.trim(line)
        IO.write("\n")

        # Add to history if non-empty
        history = if line != "", do: [line | history] |> Enum.take(100), else: history

        cond do
          line == "" ->
            repl_loop(host_path, history, 0, "")

          line in ["/quit", "/exit", "/q"] ->
            info("Goodbye!")

          String.starts_with?(line, "/") ->
            args = String.split(line)
            process_command(args)
            repl_loop(host_path, history, 0, "")

          true ->
            execute_input(line, host_path)
            repl_loop(host_path, history, 0, "")
        end
    end
  end

  defp read_line_with_history(buffer, history, hist_pos) do
    # Use IO.getn to read a single character
    case IO.getn("", 1) do
      :eof -> :eof

      # Enter key
      "\n" -> buffer
      "\r" -> buffer

      # Escape sequence (arrow keys)
      "\e" ->
        case IO.getn("", 2) do
          "[A" -> # Up arrow
            new_pos = min(hist_pos + 1, length(history))
            new_buffer = Enum.at(history, new_pos - 1) || ""
            {:history, new_pos, new_buffer}

          "[B" -> # Down arrow
            new_pos = max(hist_pos - 1, 0)
            new_buffer = if new_pos == 0, do: "", else: Enum.at(history, new_pos - 1) || ""
            {:history, new_pos, new_buffer}

          _ -> read_line_with_history(buffer, history, hist_pos)
        end

      # Backspace
      <<127>> ->
        new_buffer = String.slice(buffer, 0..-2//1)
        IO.write("\b \b")
        read_line_with_history(new_buffer, history, hist_pos)

      <<8>> -> # Also backspace on some terminals
        new_buffer = String.slice(buffer, 0..-2//1)
        IO.write("\b \b")
        read_line_with_history(new_buffer, history, hist_pos)

      # Regular character
      char when is_binary(char) ->
        IO.write(char)
        read_line_with_history(buffer <> char, history, hist_pos)

      _ ->
        read_line_with_history(buffer, history, hist_pos)
    end
  end

  defp execute_input(input, host_path) do
    IO.puts("\n\e[36m┌─ OODA Loop ─────────────────────────────────┐\e[0m")

    url = @daemon_url <> "/api/command/stream"

    # Initialize state in process dictionary
    Process.put(:ooda_state, %{steps: [], current: nil, response: nil, status: :starting})

    try do
      _resp = Req.post!(url,
        json: %{message: input, path: host_path},
        into: fn {:data, data}, {req, resp} ->
          # Parse and render each SSE event immediately
          render_sse_event(data)
          {:cont, {req, resp}}
        end,
        receive_timeout: :infinity
      )

      IO.puts("\e[36m└─────────────────────────────────────────────┘\e[0m")

      final_state = Process.get(:ooda_state)
      if final_state.response do
        IO.puts("\n#{final_state.response}\n")
      end
    rescue
      _e in Req.TransportError ->
        warning("Streaming failed, using sync fallback...")
        execute_input_sync(input, host_path)

      e ->
        error("Error: #{inspect(e)}")
    end
  end

  # Parse and render SSE event immediately to terminal
  defp render_sse_event(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      if String.starts_with?(line, "data: ") do
        json_str = String.trim_leading(line, "data: ")
        case Jason.decode(json_str) do
          {:ok, event} -> render_event_line(event)
          _ -> :ok
        end
      end
    end)
  end

  defp render_event_line(%{"type" => "tool_call", "tool" => tool, "iteration" => iter}) do
    IO.write("\e[33m│ [#{iter}]\e[0m → \e[36m#{tool}\e[0m")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => true, "tool" => _tool}) do
    IO.puts(" \e[32m✓\e[0m")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => false, "tool" => _tool, "preview" => preview}) do
    short = String.slice(preview || "", 0, 40)
    IO.puts(" \e[31m✗\e[0m #{short}")
  end

  defp render_event_line(%{"type" => "complete", "response" => response}) do
    Process.put(:ooda_state, %{response: response})
    IO.puts("\e[32m│ ✓ Complete\e[0m")
  end

  defp render_event_line(%{"request_id" => _}) do
    IO.puts("\e[90m│ Starting...\e[0m")
  end

  defp render_event_line(_), do: :ok

  # Render the OODA block
  defp render_ooda_block(%{status: :done}), do: ""
  defp render_ooda_block(state) do
    # Build the steps list (scrollable history)
    steps_content = state.steps
    |> Enum.map(fn step ->
      case step do
        %{type: :result, tool: tool, success: true} ->
          Owl.Data.tag("  ✓ #{tool}", :green)
        %{type: :result, tool: tool, success: false, preview: preview} ->
          Owl.Data.tag("  ✗ #{tool}: #{String.slice(preview || "", 0, 40)}", :red)
        _ ->
          ""
      end
    end)

    # Current action (spinner area)
    current_line = case state.current do
      %{tool: tool, iteration: iter} ->
        [Owl.Data.tag("  [#{iter}] → #{tool}...", :yellow)]
      nil when state.status == :started ->
        [Owl.Data.tag("  OODA loop starting...", :light_black)]
      _ ->
        []
    end

    # Combine into a box
    lines = [
      Owl.Data.tag("┌─ OODA Steps ─────────────────────────────────┐", :cyan)
    ] ++ steps_content ++ current_line ++ [
      Owl.Data.tag("└──────────────────────────────────────────────┘", :cyan)
    ]

    lines
    |> Enum.reject(&(&1 == ""))
    |> Owl.Data.unlines()
  end

  # Process SSE chunk and update state
  defp process_sse_chunk(data, state) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, fn line, acc ->
      if String.starts_with?(line, "data: ") do
        json_str = String.trim_leading(line, "data: ")
        case Jason.decode(json_str) do
          {:ok, event} -> update_state(event, acc)
          _ -> acc
        end
      else
        acc
      end
    end)
  end

  defp update_state(%{"type" => "tool_call", "tool" => tool, "iteration" => iter}, state) do
    step = %{type: :call, tool: tool, iteration: iter, status: :running}
    %{state | current: step, status: :thinking}
  end

  defp update_state(%{"type" => "tool_result", "tool" => tool, "success" => success, "preview" => preview}, state) do
    # Complete the current step and add to history
    completed = %{type: :result, tool: tool, success: success, preview: preview}
    steps = state.steps ++ [completed]
    %{state | steps: steps, current: nil}
  end

  defp update_state(%{"type" => "complete", "response" => response}, state) do
    %{state | response: response, status: :complete}
  end

  defp update_state(%{"request_id" => _}, state) do
    %{state | status: :started}
  end

  defp update_state(_, state), do: state

  # Synchronous fallback if streaming fails
  defp execute_input_sync(input, host_path) do
    IO.write("🤔 Thinking...\n")

    case post("/api/command", %{message: input, path: host_path}) do
      {:ok, %{"status" => "ok", "response" => response, "trace" => trace}} ->
        display_trace(trace)
        IO.puts("\n#{response}\n")

      {:ok, %{"status" => "ok", "response" => response}} ->
        IO.puts("\n#{response}\n")

      {:ok, %{"status" => "needs_init", "message" => msg}} ->
        warning(msg)

      {:ok, %{"error" => reason}} ->
        error(reason)

      {:error, reason} ->
        error(inspect(reason))
    end
  end

  defp display_trace(nil), do: :ok
  defp display_trace(trace) when is_map(trace) do
    actions = trace["action_history"] || []
    if actions != [] do
      IO.puts("\n  Steps:")
      actions
      |> Enum.reverse()
      |> Enum.each(fn action ->
        tool = action["tool"] || "?"
        IO.puts("    → #{tool}")
      end)
    end
  end
  defp display_trace(_), do: :ok

  # ============================================================================
  # HTTP Client
  # ============================================================================

  defp get(path) do
    url = @daemon_url <> path

    case Req.get(url, decode_body: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp post(path, body) do
    url = @daemon_url <> path

    # Long timeout for chat - orchestrator can take multiple iterations
    timeout = if String.contains?(path, "/command"), do: 300_000, else: 30_000

    case Req.post(url, json: body, decode_body: false, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # ============================================================================
  # Daemon Management
  # ============================================================================

  defp ensure_daemon_running do
    if daemon_healthy?() do
      :ok
    else
      if docker_daemon_running?() do
        # Container exists but API not responding - wait a bit
        Process.sleep(2000)
        if daemon_healthy?(), do: :ok, else: {:error, :daemon_not_healthy}
      else
        start_docker_daemon()
      end
    end
  end

  defp daemon_healthy? do
    case get("/health") do
      {:ok, %{"status" => "ok"}} -> true
      _ -> false
    end
  end

  defp docker_daemon_running? do
    case System.cmd("docker", ["ps", "-q", "-f", "name=giulia-daemon"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp start_docker_daemon do
    info("Starting Giulia daemon container...")

    projects_path = System.get_env("GIULIA_PROJECTS_PATH", default_projects_path())

    args = [
      "run", "-d",
      "--name", "giulia-daemon",
      "--hostname", "giulia-daemon",
      "-v", "giulia_data:/data",
      "-v", "#{projects_path}:/projects",
      "-p", "4000:4000",
      @docker_image
    ]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_, 0} ->
        # Wait for daemon to be ready
        wait_for_daemon()

      {error, _} ->
        {:error, error}
    end
  end

  defp wait_for_daemon do
    wait_for_daemon(30)
  end

  defp wait_for_daemon(0), do: {:error, :timeout}
  defp wait_for_daemon(attempts) do
    Process.sleep(1000)
    if daemon_healthy?() do
      info("Daemon started.")
      :ok
    else
      wait_for_daemon(attempts - 1)
    end
  end

  defp stop_docker_daemon do
    System.cmd("docker", ["stop", "giulia-daemon"], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "giulia-daemon"], stderr_to_stdout: true)
    :ok
  end

  defp default_projects_path do
    get_working_directory() |> Path.dirname()
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_banner do
    client_ver = Giulia.Version.short_version()

    # Get server version
    server_ver = case get("/health") do
      {:ok, %{"version" => v}} -> v
      _ -> "unknown"
    end

    IO.puts("""

    +---------------------------------------------------------+
    |                       GIULIA                            |
    |            AI Development Agent (Docker Mode)           |
    +---------------------------------------------------------+
    | Client: #{String.pad_trailing(client_ver, 20)} Server: #{String.pad_trailing(server_ver, 15)}|
    +---------------------------------------------------------+

    Connected to daemon. Type /help for commands.
    """)
  end

  defp print_help do
    IO.puts("""

    Giulia Commands:

      /init [path]    Initialize a new project
      /status         Show daemon status
      /projects       List active project contexts
      /stop           Stop the Docker daemon
      /help           Show this help
      /quit           Exit interactive mode

    Index Commands (Pure Elixir - No LLM):
      /modules        List all indexed modules
      /functions      List all indexed functions
      /summary        Show project summary (for LLM context)
      /scan           Trigger re-indexing of current directory
      /indexstatus    Show indexer status

    Debug Commands:
      /trace          Show last inference trace (what the model did)

    Usage:
      giulia                    Start interactive mode
      giulia "your message"     Send a one-shot message
      giulia /init              Initialize current directory
      giulia /modules           List modules without LLM

    Environment Variables:
      GIULIA_PROJECTS_PATH      Host path to mount as /projects
      GIULIA_PATH_MAPPING       Path mapping (e.g., "C:/Dev=/projects")

    """)
  end

  defp print_status(status) do
    IO.puts("""

    Giulia Daemon Status:

      Started:         #{status["started_at"] || "unknown"}
      Uptime:          #{format_uptime(status["uptime_seconds"] || 0)}
      Active Projects: #{status["active_projects"] || 0}
      Total Requests:  #{status["total_requests"] || 0}

    """)
  end

  defp print_projects([]) do
    info("No active projects. Use `giulia /init` in a project directory.")
  end

  defp print_projects(projects) when is_list(projects) do
    IO.puts("\nActive Projects:\n")

    Enum.each(projects, fn p ->
      path = if is_map(p), do: p["path"] || p[:path], else: p
      IO.puts("  - #{path}")
    end)

    IO.puts("")
  end

  defp print_projects(_), do: info("No projects data.")

  defp format_uptime(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end
  defp format_uptime(_), do: "unknown"

  defp info(msg), do: IO.puts("\e[36m#{msg}\e[0m")
  defp success(msg), do: IO.puts("\e[32m+ #{msg}\e[0m")
  defp warning(msg), do: IO.puts("\e[33m! #{msg}\e[0m")
  defp error(msg), do: IO.puts("\e[31m- #{msg}\e[0m")

  defp confirm?(prompt) do
    response = IO.gets("#{prompt} [y/N] ") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end
end
