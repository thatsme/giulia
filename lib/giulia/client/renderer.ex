defmodule Giulia.Client.Renderer do
  @moduledoc """
  SSE streaming renderer — parses server-sent events and prints
  colorized inference loop output to the terminal.
  """

  alias Giulia.Client.HTTP
  alias Giulia.Client.Output
  alias Giulia.Client.Approval

  @spec execute_input(String.t(), String.t()) :: :ok
  def execute_input(input, host_path) do
    IO.puts("\n\e[36m┌─ Inference Loop ────────────────────────────┐\e[0m")

    url = HTTP.daemon_url() <> "/api/command/stream"

    {:ok, state_agent} = Agent.start_link(fn ->
      %{steps: [], current: nil, response: nil, status: :starting}
    end)

    try do
      _resp = Req.post!(url,
        json: %{message: input, path: host_path},
        into: fn {:data, data}, {req, resp} ->
          render_sse_event(data, state_agent)
          {:cont, {req, resp}}
        end,
        receive_timeout: :infinity
      )

      IO.puts("\e[36m└─────────────────────────────────────────────┘\e[0m")

      final_state = Agent.get(state_agent, & &1)
      if final_state.response do
        IO.puts("\n#{final_state.response}\n")
      end
    rescue
      _e in Req.TransportError ->
        Output.warning("Streaming failed, using sync fallback...")
        execute_input_sync(input, host_path)

      e ->
        Output.error("Error: #{inspect(e)}")
    after
      Agent.stop(state_agent)
    end
  end

  # Timestamp helper — returns HH:MM:SS
  defp ts do
    {_, {h, m, s}} = :calendar.local_time()
    IO.iodata_to_binary(:io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]))
  end

  # Parse and render SSE event immediately to terminal
  defp render_sse_event(data, state_agent) do
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      if String.starts_with?(line, "data: ") do
        json_str = String.trim_leading(line, "data: ")
        case Jason.decode(json_str) do
          {:ok, event} -> render_event_line(event, state_agent)
          _ -> :ok
        end
      end
    end)
  end

  defp render_event_line(%{"type" => "tool_call", "tool" => tool, "iteration" => iter} = event, _state_agent) do
    target = extract_tool_target(tool, event["params"] || %{})
    IO.write("\e[90m#{ts()}\e[0m \e[33m│ [#{iter}]\e[0m → \e[36m#{tool}\e[0m#{target}")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => true, "tool" => _tool}, _state_agent) do
    IO.puts(" \e[32m✓\e[0m")
  end

  defp render_event_line(%{"type" => "tool_result", "success" => false, "tool" => _tool, "preview" => preview}, _state_agent) do
    IO.puts(" \e[31m✗\e[0m #{preview}")
  end

  defp render_event_line(%{"type" => "tool_requires_approval", "approval_id" => approval_id, "tool" => tool, "preview" => preview}, _state_agent) do
    IO.puts("\n\e[90m#{ts()}\e[0m \e[1;33m│ APPROVAL: #{tool}\e[0m (#{approval_id})")
    preview_text = preview || "(no preview)"
    preview_text
    |> String.split("\n")
    |> Enum.take(30)
    |> Enum.each(fn line -> IO.puts("│   #{colorize_diff_line_ansi(line)}") end)

    approved = Approval.prompt()
    Approval.send_response(approval_id, approved)
    if approved, do: IO.puts("\e[32m│ ✓ Approved\e[0m"), else: IO.puts("\e[31m│ ✗ Rejected\e[0m")
  end

  defp render_event_line(%{"type" => "approval_granted", "tool" => _tool}, _state_agent), do: :ok
  defp render_event_line(%{"type" => "approval_rejected", "tool" => _tool}, _state_agent), do: :ok
  defp render_event_line(%{"type" => "approval_timeout", "tool" => tool}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[33m│ Timeout: #{tool}\e[0m")
  end

  defp render_event_line(%{"type" => "verification_started", "tool" => tool}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ VERIFY: #{tool} (mix compile)\e[0m")
  end

  defp render_event_line(%{"type" => "verification_passed", "message" => message}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ ✓ #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "verification_failed", "errors" => errors}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ BUILD BROKEN - model must fix:\e[0m")
    IO.puts("\e[31m│   #{errors}\e[0m")
  end

  defp render_event_line(%{"type" => "complete", "response" => response}, state_agent) do
    Agent.update(state_agent, fn state -> %{state | response: response} end)
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ ✓ Complete\e[0m")
  end

  defp render_event_line(%{"request_id" => _}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[90m│ Starting...\e[0m")
  end

  defp render_event_line(%{"type" => "baseline_warning", "message" => message}, _state_agent) do
    IO.puts("")
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m⚠ BASELINE WARNING\e[0m")
    IO.puts("\e[33m#{message}\e[0m")
    IO.puts("\e[33mGiulia will not blame herself for pre-existing errors.\e[0m")
    IO.puts("")
  end

  defp render_event_line(%{"type" => "escalation_triggered", "message" => message}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;35m│ ESCALATION: #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_started", "message" => message}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[35m│ #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_complete", "message" => _message, "instructions" => instructions} = event, _state_agent) do
    provider = event["provider"] || "Cloud"
    IO.puts("\e[90m#{ts()}\e[0m \e[1;32m│ SENIOR ARCHITECT (#{provider}):\e[0m")
    (instructions || "(no instructions)")
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("\e[37m│   #{line}\e[0m") end)
    IO.puts("\e[33m│ Feeding to local model...\e[0m")
  end

  defp render_event_line(%{"type" => "escalation_failed", "message" => message}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ ESCALATION FAILED: #{message}\e[0m")
  end

  defp render_event_line(%{"type" => "model_detected", "model" => model, "tier" => tier}, _state_agent) do
    tier_color = case tier do
      "small"  -> "\e[33m"
      "medium" -> "\e[36m"
      "large"  -> "\e[32m"
      _        -> "\e[37m"
    end
    IO.puts("\e[90m#{ts()}\e[0m \e[90m│ Model: #{model} #{tier_color}[#{tier}]\e[0m")
  end

  defp render_event_line(%{"type" => "transaction_auto_enabled", "reason" => reason}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ TRANSACTION MODE auto-enabled (#{reason})\e[0m")
  end

  defp render_event_line(%{"type" => "transaction_auto_enabled", "module" => module}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ TRANSACTION MODE auto-enabled (hub module: #{module})\e[0m")
  end

  defp render_event_line(%{"type" => "commit_started", "file_count" => count} = event, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Flushing #{count} file(s) to disk...\e[0m")
    render_file_list(event["files"], "  \e[90m")
  end

  defp render_event_line(%{"type" => "commit_compiling"}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Compiling...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_compile_passed"} = event, _state_agent) do
    suffix = if event["warnings"], do: " (with warnings)", else: ""
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ COMMIT: Compile passed#{suffix}\e[0m")
  end

  defp render_event_line(%{"type" => "commit_integrity_checking"}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Integrity check...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_integrity_passed"}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[32m│ COMMIT: Integrity check passed\e[0m")
  end

  defp render_event_line(%{"type" => "commit_testing", "test_count" => count}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[36m│ COMMIT: Running #{count} regression test(s)...\e[0m")
  end

  defp render_event_line(%{"type" => "commit_success", "file_count" => count} = event, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;32m│ COMMIT SUCCESS: #{count} file(s) verified and written\e[0m")
    render_file_list(event["files"], "  \e[32m")
  end

  defp render_event_line(%{"type" => "commit_rollback", "message" => message} = event, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;31m│ ROLLBACK: #{message}\e[0m")
    render_file_list(event["files"], "  \e[31m")
    if errors = event["errors"], do: IO.puts("  \e[31m#{errors}\e[0m")
  end

  defp render_event_line(%{"type" => "architectural_fracture", "fractures" => report}, _state_agent) do
    IO.puts("\n\e[90m#{ts()}\e[0m \e[1;31m│ ARCHITECTURAL FRACTURE: Behaviour-implementer mismatch\e[0m")
    report
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("\e[31m│   #{line}\e[0m") end)
    IO.puts("\e[31m│   All changes rolled back.\e[0m")
  end

  defp render_event_line(%{"type" => "goal_tracker_block", "module" => mod, "dependents" => deps, "modified" => touched}, _state_agent) do
    IO.puts("\e[90m#{ts()}\e[0m \e[1;33m│ GOAL TRACKER: Only #{touched}/#{deps} dependents of #{mod} modified — respond BLOCKED\e[0m")
  end

  defp render_event_line(%{"type" => "bulk_replace"}, _state_agent) do
    :ok
  end

  defp render_event_line(_, _state_agent), do: :ok

  defp extract_tool_target(tool, params) when is_map(params) do
    case tool do
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
  end
  defp extract_tool_target(_, _), do: ""

  defp render_file_list(nil, _prefix), do: :ok
  defp render_file_list([], _prefix), do: :ok
  defp render_file_list(files, prefix) when is_list(files) do
    Enum.each(files, fn path ->
      basename = Path.basename(to_string(path))
      IO.puts("#{prefix}  → #{basename}\e[0m")
    end)
  end

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

  # Synchronous fallback if streaming fails
  defp execute_input_sync(input, host_path) do
    IO.write("🤔 Thinking...\n")

    case HTTP.post("/api/command", %{message: input, path: host_path}) do
      {:ok, %{"status" => "ok", "response" => response, "trace" => trace}} ->
        display_trace(trace)
        IO.puts("\n#{response}\n")

      {:ok, %{"status" => "ok", "response" => response}} ->
        IO.puts("\n#{response}\n")

      {:ok, %{"status" => "needs_init", "message" => msg}} ->
        Output.warning(msg)

      {:ok, %{"error" => reason}} ->
        Output.error(reason)

      {:error, reason} ->
        Output.error(inspect(reason))
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
end
