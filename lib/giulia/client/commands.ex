defmodule Giulia.Client.Commands do
  @moduledoc """
  Slash command dispatch — routes /init, /status, /modules, etc.
  """

  alias Giulia.Client
  alias Giulia.Client.{HTTP, Output, Renderer, REPL}

  @spec process([String.t()]) :: :ok
  def process([]) do
    REPL.start()
  end

  def process(["/init" | rest]) do
    path = List.first(rest) || Client.get_working_directory()

    case Client.init_project(path) do
      {:ok, %{"status" => "initialized"}} ->
        Output.success("Project initialized at #{path}")
        Output.info("Created GIULIA.md - edit this to define your project's constitution.")

      {:ok, %{"error" => reason}} ->
        Output.error("Failed to initialize: #{reason}")

      {:error, reason} ->
        Output.error("Failed to initialize: #{inspect(reason)}")
    end
  end

  def process(["/status"]) do
    case Client.status() do
      {:ok, status} ->
        Output.print_status(status)

      {:error, reason} ->
        Output.error("Failed to get status: #{inspect(reason)}")
    end
  end

  def process(["/projects"]) do
    case Client.list_projects() do
      {:ok, %{"projects" => projects}} ->
        Output.print_projects(projects)

      {:error, reason} ->
        Output.error("Failed to list projects: #{inspect(reason)}")
    end
  end

  def process(["/stop"]) do
    Output.info("Stopping Giulia daemon...")
    Giulia.Client.Daemon.stop()
    Output.success("Daemon stopped.")
  end

  def process(["/help"]) do
    Output.print_help()
  end

  def process(["/search" | rest]) do
    case rest do
      [] ->
        Output.warning("Usage: /search <pattern>")

      terms ->
        pattern = Enum.join(terms, " ")
        host_path = Client.get_working_directory()

        case HTTP.get("/api/search?pattern=#{URI.encode(pattern)}&path=#{URI.encode(host_path)}") do
          {:ok, %{"results" => results}} ->
            IO.puts("\n\e[36mSearch: '#{pattern}'\e[0m\n")
            IO.puts(results)
            IO.puts("")

          {:error, reason} ->
            Output.error("Search failed: #{inspect(reason)}")
        end
    end
  end

  def process(["/modules"]) do
    case HTTP.get("/api/index/modules") do
      {:ok, %{"modules" => modules, "count" => count}} ->
        IO.puts("\nIndexed Modules (#{count}):\n")
        for mod <- modules do
          IO.puts("  #{mod["name"]}")
          IO.puts("    File: #{mod["file"]}:#{mod["line"]}")
        end
        IO.puts("")

      {:error, reason} ->
        Output.error("Failed to get modules: #{inspect(reason)}")
    end
  end

  def process(["/functions"]) do
    case HTTP.get("/api/index/functions") do
      {:ok, %{"functions" => functions, "count" => count}} ->
        IO.puts("\nIndexed Functions (#{count}):\n")
        for {module, funcs} <- Enum.group_by(functions, & &1["module"]) do
          IO.puts("  #{module}:")
          for f <- funcs do
            visibility = if f["type"] == "def", do: "pub", else: "priv"
            IO.puts("    #{f["name"]}/#{f["arity"]} [#{visibility}]")
          end
        end
        IO.puts("")

      {:error, reason} ->
        Output.error("Failed to get functions: #{inspect(reason)}")
    end
  end

  def process(["/summary"]) do
    case HTTP.get("/api/index/summary") do
      {:ok, %{"summary" => summary}} ->
        IO.puts("\n#{summary}")

      {:error, reason} ->
        Output.error("Failed to get summary: #{inspect(reason)}")
    end
  end

  def process(["/scan"]) do
    host_path = Client.get_working_directory()

    case HTTP.post("/api/index/scan", %{path: host_path}) do
      {:ok, %{"status" => "scanning", "path" => path}} ->
        Output.info("Started scanning: #{path}")
        Output.info("Use /indexstatus to check progress.")

      {:error, reason} ->
        Output.error("Failed to start scan: #{inspect(reason)}")
    end
  end

  def process(["/indexstatus"]) do
    case HTTP.get("/api/index/status") do
      {:ok, status} ->
        IO.puts("\nIndexer Status:")
        IO.puts("  Status: #{status["status"]}")
        IO.puts("  Project: #{status["project_path"] || "none"}")
        IO.puts("  Files: #{status["file_count"]}")
        if status["last_scan"], do: IO.puts("  Last Scan: #{status["last_scan"]}")
        IO.puts("")

      {:error, reason} ->
        Output.error("Failed to get indexer status: #{inspect(reason)}")
    end
  end

  def process(["/transaction"]) do
    host_path = Client.get_working_directory()

    case HTTP.post("/api/transaction/enable", %{path: host_path}) do
      {:ok, %{"status" => "enabled", "transaction_mode" => true}} ->
        Output.success("Transaction mode ENABLED. Writes are now staged.")
        Output.info("Use /staged to view staged files, commit_changes to flush.")

      {:ok, %{"status" => "disabled", "transaction_mode" => false}} ->
        Output.info("Transaction mode DISABLED. Writes go directly to disk.")

      {:ok, %{"error" => reason}} ->
        Output.error("Failed: #{reason}")

      {:error, reason} ->
        Output.error("Failed to toggle transaction mode: #{inspect(reason)}")
    end
  end

  def process(["/staged"]) do
    host_path = Client.get_working_directory()

    case HTTP.get("/api/transaction/staged?path=#{URI.encode(host_path)}") do
      {:ok, %{"transaction_mode" => true, "staged_files" => files, "count" => count}} ->
        IO.puts("\nTransaction Mode: \e[32mACTIVE\e[0m")
        IO.puts("Staged Files (#{count}):\n")
        Enum.each(files, fn %{"path" => path, "size" => size} ->
          IO.puts("  #{path} (#{size} bytes)")
        end)
        IO.puts("\nUse commit_changes in the inference loop to flush to disk.\n")

      {:ok, %{"transaction_mode" => false}} ->
        Output.info("Transaction mode is not active. No files staged.")

      {:error, reason} ->
        Output.error("Failed to get staged files: #{inspect(reason)}")
    end
  end

  def process(["/trace"]) do
    case HTTP.get("/api/agent/last_trace") do
      {:ok, %{"trace" => nil}} ->
        Output.info("No inference trace available yet.")

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
        Output.error("Failed to get trace: #{inspect(reason)}")
    end
  end

  def process(["/integrity"]) do
    case HTTP.get("/api/knowledge/integrity") do
      {:ok, %{"status" => "consistent"}} ->
        Output.success("All behaviours consistent. No architectural fractures.")

      {:ok, %{"status" => "fractured", "fractures" => fractures}} ->
        Output.error("ARCHITECTURAL FRACTURE(S) detected:\n")
        Enum.each(fractures, fn %{"behaviour" => behaviour, "fractures" => impl_fractures} ->
          IO.puts("  \e[1;31mBEHAVIOUR #{behaviour}:\e[0m")
          Enum.each(impl_fractures, fn %{"implementer" => impl, "missing" => missing} ->
            missing_str = Enum.join(missing, ", ")
            IO.puts("    - #{impl}: missing #{missing_str}")
          end)
        end)
        IO.puts("")

      {:error, reason} ->
        Output.error("Integrity check failed: #{inspect(reason)}")
    end
  end

  def process(args) do
    # Treat as chat message
    message = Enum.join(args, " ")
    host_path = Client.get_working_directory()
    Renderer.execute_input(message, host_path)
  end
end
