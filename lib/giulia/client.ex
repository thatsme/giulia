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
    # Fix MSYS/Git Bash path mangling: /integrity → C:/Program Files/Git/integrity
    args = Enum.map(args, &fix_msys_path/1)

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

  # Fix MSYS/Git Bash path mangling on Windows.
  # Git Bash converts /foo to C:/Program Files/Git/foo automatically.
  # We detect and reverse this for slash commands.
  defp fix_msys_path(arg) do
    msys_prefix = "C:/Program Files/Git/"

    if String.starts_with?(arg, msys_prefix) do
      "/" <> String.replace_prefix(arg, msys_prefix, "")
    else
      arg
    end
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

  defp process_command(["/search" | rest]) do
    case rest do
      [] ->
        warning("Usage: /search <pattern>")

      terms ->
        pattern = Enum.join(terms, " ")
        host_path = get_working_directory()

        case get("/api/search?pattern=#{URI.encode(pattern)}&path=#{URI.encode(host_path)}") do
          {:ok, %{"results" => results}} ->
            IO.puts("\n\e[36mSearch: '#{pattern}'\e[0m\n")
            IO.puts(results)
            IO.puts("")

          {:error, reason} ->
            error("Search failed: #{inspect(reason)}")
        end
    end
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

  defp process_command(["/transaction"]) do
    host_path = get_working_directory()

    case post("/api/transaction/enable", %{path: host_path}) do
      {:ok, %{"status" => "enabled", "transaction_mode" => true}} ->
        success("Transaction mode ENABLED. Writes are now staged.")
        info("Use /staged to view staged files, commit_changes to flush.")

      {:ok, %{"status" => "disabled", "transaction_mode" => false}} ->
        info("Transaction mode DISABLED. Writes go directly to disk.")

      {:ok, %{"error" => reason}} ->
        error("Failed: #{reason}")

      {:error, reason} ->
        error("Failed to toggle transaction mode: #{inspect(reason)}")
    end
  end

  defp process_command(["/staged"]) do
    host_path = get_working_directory()

    case get("/api/transaction/staged?path=#{URI.encode(host_path)}") do
      {:ok, %{"transaction_mode" => true, "staged_files" => files, "count" => count}} ->
        IO.puts("\nTransaction Mode: \e[32mACTIVE\e[0m")
        IO.puts("Staged Files (#{count}):\n")
        Enum.each(files, fn %{"path" => path, "size" => size} ->
          IO.puts("  #{path} (#{size} bytes)")
        end)
        IO.puts("\nUse commit_changes in the OODA loop to flush to disk.\n")

      {:ok, %{"transaction_mode" => false}} ->
        info("Transaction mode is not active. No files staged.")

      {:error, reason} ->
        error("Failed to get staged files: #{inspect(reason)}")
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

  defp process_command(["/integrity"]) do
    case get("/api/knowledge/integrity") do
      {:ok, %{"status" => "consistent"}} ->
        success("All behaviours consistent. No architectural fractures.")

      {:ok, %{"status" => "fractured", "fractures" => fractures}} ->
        error("ARCHITECTURAL FRACTURE(S) detected:\n")
        Enum.each(fractures, fn %{"behaviour" => behaviour, "fractures" => impl_fractures} ->
          IO.puts("  \e[1;31mBEHAVIOUR #{behaviour}:\e[0m")
          Enum.each(impl_fractures, fn %{"implementer" => impl, "missing" => missing} ->
            missing_str = Enum.join(missing, ", ")
            IO.puts("    - #{impl}: missing #{missing_str}")
          end)
        end)
        IO.puts("")

      {:error, reason} ->
        error("Integrity check failed: #{inspect(reason)}")
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

    # Check if project is initialized (lightweight ping - no inference)
    case post("/api/ping", %{path: host_path}) do
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

  # Simple REPL with history recall via /history and !N
  # Supports multiline input:
  #   """  ... heredoc mode ...  """    (preserves blank lines)
  #   line ending with \                (continuation, joins with space)
  defp repl_loop(host_path), do: repl_loop(host_path, [])

  defp repl_loop(host_path, history) do
    case read_full_input() do
      :eof ->
        info("\nGoodbye!")

      line ->
        cond do
          line == "" ->
            repl_loop(host_path, history)

          line in ["/quit", "/exit", "/q"] ->
            info("Goodbye!")

          line == "/history" ->
            print_history(history)
            repl_loop(host_path, history)

          # !N - replay command N from history
          Regex.match?(~r/^!(\d+)$/, line) ->
            [_, num_str] = Regex.run(~r/^!(\d+)$/, line)
            num = String.to_integer(num_str)
            case Enum.at(history, num - 1) do
              nil ->
                warning("No command ##{num} in history")
                repl_loop(host_path, history)
              cmd ->
                info("Replaying: #{cmd}")
                history = [cmd | history] |> Enum.take(100)
                execute_or_command(cmd, host_path)
                repl_loop(host_path, history)
            end

          # !! - replay last command
          line == "!!" ->
            case List.first(history) do
              nil ->
                warning("No previous command")
                repl_loop(host_path, history)
              cmd ->
                info("Replaying: #{cmd}")
                execute_or_command(cmd, host_path)
                repl_loop(host_path, history)
            end

          String.starts_with?(line, "/") ->
            history = [line | history] |> Enum.take(100)
            args = String.split(line)
            process_command(args)
            repl_loop(host_path, history)

          true ->
            history = [line | history] |> Enum.take(100)
            execute_input(line, host_path)
            repl_loop(host_path, history)
        end
    end
  end

  # ============================================================================
  # Multiline Input — heredoc (""") and continuation (\)
  # ============================================================================

  @heredoc_delim ~s(""")

  # Read a full input line, handling multiline modes:
  #   """         → heredoc mode (read until closing """)
  #   """text     → inline heredoc open (read until closing """)
  #   """text"""  → single-line heredoc (both delimiters on same line)
  #   line\       → continuation (joins with newline)
  defp read_full_input do
    case IO.gets("giulia> ") do
      :eof ->
        :eof

      raw ->
        line = raw |> to_string() |> strip_newline()

        trimmed = String.trim(line)

        cond do
          # Exact """ on its own line — open heredoc, read until """
          trimmed == @heredoc_delim ->
            IO.puts("\e[90m  (multiline mode — close with \"\"\" on its own line)\e[0m")
            read_heredoc([])

          # Line starts with """ — inline open
          String.starts_with?(trimmed, @heredoc_delim) ->
            after_open = String.replace_prefix(trimmed, @heredoc_delim, "")
            # Check if line also ENDS with """ (single-line: """text""")
            if String.length(after_open) >= 3 and String.ends_with?(after_open, @heredoc_delim) do
              # Single-line heredoc: extract between the two """
              after_open |> String.replace_suffix(@heredoc_delim, "") |> String.trim()
            else
              # Inline open, read more lines until closing """
              read_heredoc([after_open])
            end

          # Continuation: end a line with \ to keep typing
          String.ends_with?(trimmed, "\\") ->
            first = String.slice(trimmed, 0, String.length(trimmed) - 1) |> String.trim_trailing()
            read_continuation([first])

          true ->
            trimmed
        end
    end
  end

  # Strip trailing \r\n or \n
  defp strip_newline(s), do: s |> String.trim_trailing("\n") |> String.trim_trailing("\r")

  # Read lines until closing """ delimiter
  # Handles: """ on its own line, or text""" at end of line
  defp read_heredoc(acc) do
    case IO.gets("...  ") do
      :eof ->
        acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

      raw ->
        line = raw |> to_string() |> strip_newline()
        trimmed = String.trim(line)

        cond do
          # Closing """ on its own line
          trimmed == @heredoc_delim ->
            acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

          # Line ends with """ (inline close: text""")
          String.ends_with?(trimmed, @heredoc_delim) ->
            last_part = String.replace_suffix(trimmed, @heredoc_delim, "")
            [last_part | acc] |> Enum.reverse() |> Enum.join("\n") |> String.trim()

          true ->
            read_heredoc([line | acc])
        end
    end
  end

  # Read continuation lines (trailing \) until a line without \
  defp read_continuation(acc) do
    case IO.gets("...  ") do
      :eof ->
        acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

      raw ->
        line = raw |> to_string() |> strip_newline() |> String.trim()

        if String.ends_with?(line, "\\") do
          part = String.slice(line, 0, String.length(line) - 1) |> String.trim_trailing()
          read_continuation([part | acc])
        else
          [line | acc] |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        end
    end
  end

  defp execute_or_command(cmd, host_path) do
    if String.starts_with?(cmd, "/") do
      args = String.split(cmd)
      process_command(args)
    else
      execute_input(cmd, host_path)
    end
  end

  defp print_history([]) do
    info("No history yet.")
  end

  defp print_history(history) do
    IO.puts("\n  \e[36mHistory:\e[0m")
    history
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.each(fn {cmd, idx} ->
      # Truncate long commands
      display = if String.length(cmd) > 60, do: String.slice(cmd, 0, 57) <> "...", else: cmd
      IO.puts("  \e[33m#{String.pad_leading(Integer.to_string(idx), 3)}\e[0m  #{display}")
    end)
    IO.puts("")
    info("Use !N to replay command #N, or !! to replay last command")
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

  # Timestamp helper — returns HH:MM:SS
  defp ts do
    {_, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
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

  defp render_event_line(%{"type" => "tool_call", "tool" => tool, "iteration" => iter} = event) do
    target = extract_tool_target(tool, event["params"] || %{})
    IO.write("\e[90m#{ts()}\e[0m \e[33m│ [#{iter}]\e[0m → \e[36m#{tool}\e[0m#{target}")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => true, "tool" => _tool}) do
    IO.puts(" \e[32m✓\e[0m")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => false, "tool" => _tool, "preview" => preview}) do
    IO.puts(" \e[31m✗\e[0m #{preview}")
  end

  # Approval gate - simple output
  defp render_event_line(%{"type" => "tool_requires_approval", "approval_id" => approval_id, "tool" => tool, "preview" => preview}) do
    IO.puts("\n\e[90m#{ts()}\e[0m \e[1;33m│ APPROVAL: #{tool}\e[0m (#{approval_id})")
    preview_text = preview || "(no preview)"
    preview_text
    |> String.split("\n")
    |> Enum.take(30)
    |> Enum.each(fn line -> IO.puts("│   #{colorize_diff_line_ansi(line)}") end)

    approved = prompt_approval()
    send_approval_response(approval_id, approved)
    if approved, do: IO.puts("\e[32m│ ✓ Approved\e[0m"), else: IO.puts("\e[31m│ ✗ Rejected\e[0m")
  end

  defp render_event_line(%{"type" => "approval_granted", "tool" => _tool}), do: :ok
  defp render_event_line(%{"type" => "approval_rejected", "tool" => _tool}), do: :ok
  defp render_event_line(%{"type" => "approval_timeout", "tool" => tool}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[33m│ Timeout: #{tool}\e[0m")
  end

  # Verification events
  defp render_event_line(%{"type" => "verification_started", "tool" => tool}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ VERIFY: #{tool} (mix compile)\e[0m")
  end

  defp render_event_line(%{"type" => "verification_passed", "message" => message}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ ✓ #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "verification_failed", "errors" => errors}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ BUILD BROKEN - model must fix:\e[0m")
    IO.puts("\e[31m│   #{errors}\e[0m")
  end

  defp render_event_line(%{"type" => "complete", "response" => response}) do
    Process.put(:ooda_state, %{response: response})
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ ✓ Complete\e[0m")
  end

  defp render_event_line(%{"request_id" => _}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[90m│ Starting...\e[0m")
  end

  # Baseline warning - project was already broken before we started
  defp render_event_line(%{"type" => "baseline_warning", "message" => message}) do
    IO.puts("")
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m⚠ BASELINE WARNING\e[0m")
    IO.puts("\e[33m#{message}\e[0m")
    IO.puts("\e[33mGiulia will not blame herself for pre-existing errors.\e[0m")
    IO.puts("")
  end

  # HYBRID ESCALATION Events
  defp render_event_line(%{"type" => "escalation_triggered", "message" => message}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;35m│ ESCALATION: #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_started", "message" => message}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[35m│ #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_complete", "message" => _message, "instructions" => instructions} = event) do
    provider = event["provider"] || "Cloud"
    IO.puts("\e[90m#{ts()}\e[0m \e[1;32m│ SENIOR ARCHITECT (#{provider}):\e[0m")
    (instructions || "(no instructions)")
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("\e[37m│   #{line}\e[0m") end)
    IO.puts("\e[33m│ Feeding to local model...\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_failed", "message" => message}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ ESCALATION FAILED: #{message}\e[0m")
  end

  # Model detection event
  defp render_event_line(%{"type" => "model_detected", "model" => model, "tier" => tier}) do
    tier_color = case tier do
      "small"  -> "\e[33m"   # yellow
      "medium" -> "\e[36m"   # cyan
      "large"  -> "\e[32m"   # green
      _        -> "\e[37m"   # white
    end
    IO.puts("\e[90m#{ts()}\e[0m \e[90m│ Model: #{model} #{tier_color}[#{tier}]\e[0m")
  end

  # Transaction lifecycle events
  defp render_event_line(%{"type" => "transaction_auto_enabled", "reason" => reason}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ TRANSACTION MODE auto-enabled (#{reason})\e[0m")
  end

  defp render_event_line(%{"type" => "transaction_auto_enabled", "module" => module}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ TRANSACTION MODE auto-enabled (hub module: #{module})\e[0m")
  end

  defp render_event_line(%{"type" => "commit_started", "file_count" => count} = event) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Flushing #{count} file(s) to disk...\e[0m")
    render_file_list(event["files"], "  \e[90m")
  end

  defp render_event_line(%{"type" => "commit_compiling"}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Compiling...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_compile_passed"} = event) do
    suffix = if event["warnings"], do: " (with warnings)", else: ""
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ COMMIT: Compile passed#{suffix}\e[0m")
  end

  defp render_event_line(%{"type" => "commit_integrity_checking"}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Integrity check...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_integrity_passed"}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ COMMIT: Integrity check passed\e[0m")
  end

  defp render_event_line(%{"type" => "commit_testing", "test_count" => count}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Running #{count} regression test(s)...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_success", "file_count" => count} = event) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;32m│ COMMIT SUCCESS: #{count} file(s) verified and written\e[0m")
    render_file_list(event["files"], "  \e[32m")
  end

  defp render_event_line(%{"type" => "commit_rollback", "message" => message} = event) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ ROLLBACK: #{message}\e[0m")
    render_file_list(event["files"], "  \e[31m")
    if errors = event["errors"], do: IO.puts("  \e[31m#{errors}\e[0m")
  end

  defp render_event_line(%{"type" => "architectural_fracture", "fractures" => report}) do
    IO.puts("\n\e[90m#{ts()}\e[0m \e[1;31m│ ARCHITECTURAL FRACTURE: Behaviour-implementer mismatch\e[0m")
    report
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("\e[31m│   #{line}\e[0m") end)
    IO.puts("\e[31m│   All changes rolled back.\e[0m")
  end

  defp render_event_line(%{"type" => "goal_tracker_block", "module" => mod, "dependents" => deps, "modified" => touched}) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ GOAL TRACKER: Only #{touched}/#{deps} dependents of #{mod} modified — respond BLOCKED\e[0m")
  end

  defp render_event_line(%{"type" => "bulk_replace"}) do
    # Handled by tool_call/tool_result events
    :ok
  end

  defp render_event_line(_), do: :ok

  # Extract a human-readable target from tool params
  defp extract_tool_target(tool, params) when is_map(params) do
    target = case tool do
      t when t in ["patch_function", "write_function"] ->
        mod = params["module"] || ""
        func = params["function_name"] || ""
        arity = params["arity"]
        if func != "", do: " \e[37m#{mod}.#{func}/#{arity}\e[0m", else: ""

      t when t in ["edit_file", "write_file", "read_file"] ->
        file = params["file"] || params["path"] || ""
        if file != "", do: " \e[37m#{Path.basename(file)}\e[0m", else: ""

      "get_function" ->
        func = params["function_name"] || ""
        file = params["file"] || params["module"] || ""
        if func != "", do: " \e[37m#{func} in #{Path.basename(to_string(file))}\e[0m", else: ""

      "get_impact_map" ->
        mod = params["module"] || ""
        if mod != "", do: " \e[37m#{mod}\e[0m", else: ""

      "search_code" ->
        pattern = params["pattern"] || ""
        if pattern != "", do: " \e[37m\"#{pattern}\"\e[0m", else: ""

      "bulk_replace" ->
        pattern = params["pattern"] || ""
        replacement = params["replacement"] || ""
        files = params["files"] || params["file_list"]
        count = if is_list(files), do: length(files), else: files
        " \e[37m'#{pattern}' → '#{replacement}' (#{count} files)\e[0m"

      "think" ->
        thought = params["thought"] || ""
        short = if String.length(thought) > 60, do: String.slice(thought, 0, 57) <> "...", else: thought
        if short != "", do: " \e[90m#{short}\e[0m", else: ""

      _ -> ""
    end
    target
  end
  defp extract_tool_target(_, _), do: ""

  # Render a file list under a commit/rollback event
  defp render_file_list(nil, _prefix), do: :ok
  defp render_file_list([], _prefix), do: :ok
  defp render_file_list(files, prefix) when is_list(files) do
    Enum.each(files, fn path ->
      basename = Path.basename(to_string(path))
      IO.puts("#{prefix}  → #{basename}\e[0m")
    end)
  end

  # ============================================================================
  # Owl Formatting Helpers
  # ============================================================================

  # Simple ANSI colorization for diff lines
  defp colorize_diff_line_ansi(line) do
    cond do
      String.starts_with?(line, "@@") ->
        "\e[36m#{line}\e[0m"

      String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
        "\e[1;37m#{line}\e[0m"

      String.starts_with?(line, "-") ->
        "\e[31m#{line}\e[0m"

      String.starts_with?(line, "+") ->
        "\e[32m#{line}\e[0m"

      String.starts_with?(line, "===") ->
        "\e[1;33m#{line}\e[0m"

      String.starts_with?(line, "Module:") or String.starts_with?(line, "Function:") or String.starts_with?(line, "File:") ->
        "\e[36m#{line}\e[0m"

      true ->
        line
    end
  end

  # ============================================================================
  # Approval Helpers
  # ============================================================================

  # Prompt user for approval
  defp prompt_approval do
    response = IO.gets("\e[1;33mApprove? [y/N]\e[0m ") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end

  # Send approval response to daemon
  defp send_approval_response(approval_id, approved) do
    # URL-encode the approval_id since it contains special chars (#, <, >, .)
    encoded_id = URI.encode(approval_id, &URI.char_unreserved?/1)
    url = @daemon_url <> "/api/approval/#{encoded_id}"

    case Req.post(url, json: %{approved: approved}, decode_body: false, receive_timeout: 5000) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        IO.puts("\e[31mWarning: Failed to send approval (#{status}): #{body}\e[0m")

      {:error, reason} ->
        IO.puts("\e[31mWarning: Failed to send approval: #{inspect(reason)}\e[0m")
    end
  end

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

    # Get active model from LM Studio
    model_name = detect_active_model()

    # Check Giulia daemon status
    daemon_status = case get("/api/index/status") do
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

  # Query LM Studio /v1/models to get the active model name
  # The client talks directly to LM Studio (not through the daemon)
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

  defp print_help do
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
