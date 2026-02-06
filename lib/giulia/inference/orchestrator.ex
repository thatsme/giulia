defmodule Giulia.Inference.Orchestrator do
  @moduledoc """
  The Central Nervous System - OODA Loop State Machine.

  OBSERVE -> ORIENT -> DECIDE -> ACT -> OBSERVE...

  This GenServer manages the thinking loop:
  1. START   - Receive user prompt
  2. THINK   - Call model (Router decides: 3B or Cloud)
  3. PARSE   - Extract JSON tool call via StructuredOutput
  4. VALIDATE - Run through Ecto changeset
  5. EXECUTE - Run the tool
  6. VERIFY  - If write/edit, auto-compile and check
  7. OBSERVE - Feed result back into chat history
  8. LOOP    - Until model says "respond" or max iterations

  KEY INSIGHT: Uses handle_continue/2 for async looping.
  The GenServer remains responsive to :cancel, :status messages
  even while the thinking loop runs.

  SENIOR GUARDRAILS:
  - Auto-verify after write_file/edit_file (run compile)
  - Loop of death prevention (3 consecutive failures → intervention)
  - Distilled context injection (modules, cwd, last 3 actions)
  """
  use GenServer

  require Logger

  alias Giulia.Provider.Router
  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry
  alias Giulia.StructuredOutput
  alias Giulia.StructuredOutput.Parser
  alias Giulia.Context.Store
  alias Giulia.Core.{ProjectContext, PathMapper, PathSandbox}
  alias Giulia.Inference.{Trace, Approval, Events}
  alias Giulia.Utils.Diff

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  defstruct [
    # Task info
    task: nil,
    project_path: nil,
    project_pid: nil,
    reply_to: nil,
    request_id: nil,  # For event broadcasting

    # State machine
    # :idle | :starting | :thinking | :waiting_for_approval | :paused
    status: :idle,
    messages: [],

    # Loop tracking
    iteration: 0,
    max_iterations: 15,
    consecutive_failures: 0,
    max_failures: 3,

    # History for context injection and loop detection
    last_action: nil,
    action_history: [],    # Last N actions for context
    recent_errors: [],     # For intervention messages

    # Provider
    provider: nil,
    provider_module: nil,

    # Result
    final_response: nil,

    # Verification
    pending_verification: false,

    # Baseline check - was project broken before we started?
    baseline_status: :unknown,  # :clean | :dirty | :unknown

    # Approval state - for non-blocking approval flow
    pending_approval: nil,  # %{approval_id, tool, params, response} when waiting

    # HYBRID ESCALATION - track syntax repair failures
    syntax_failures: 0,       # Count of failed syntax repair attempts
    escalated: false,         # Have we already called Sonnet this session?
    original_provider: nil,   # Remember original provider for switching back
    last_compile_error: nil   # Store compile error for escalation context
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute a task synchronously. Blocks until complete.
  """
  def execute(orchestrator, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenServer.call(orchestrator, {:execute, prompt, opts}, timeout)
  end

  @doc """
  Execute asynchronously. Returns immediately, sends result via message.
  """
  def execute_async(orchestrator, prompt, opts \\ []) do
    GenServer.cast(orchestrator, {:execute_async, prompt, opts, self()})
  end

  @doc """
  Get current state (for debugging/monitoring).
  """
  def get_state(orchestrator) do
    GenServer.call(orchestrator, :get_state)
  end

  @doc """
  Cancel the current task.
  """
  def cancel(orchestrator) do
    GenServer.cast(orchestrator, :cancel)
  end

  @doc """
  Pause the thinking loop (can resume later).
  """
  def pause(orchestrator) do
    GenServer.cast(orchestrator, :pause)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      project_path: Keyword.get(opts, :project_path),
      project_pid: Keyword.get(opts, :project_pid)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, prompt, opts}, from, state) do
    # Generate request ID for event broadcasting
    request_id = Keyword.get(opts, :request_id, make_ref() |> inspect())

    # Start the loop, reply will be sent via handle_continue
    state = %{state |
      task: prompt,
      reply_to: from,
      status: :starting,
      request_id: request_id
    }
    {:noreply, state, {:continue, {:start, prompt, opts}}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_cast({:execute_async, prompt, opts, reply_pid}, state) do
    state = %{state |
      task: prompt,
      reply_to: {:async, reply_pid},
      status: :starting
    }
    {:noreply, state, {:continue, {:start, prompt, opts}}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Orchestrator cancelled")
    send_reply(state, {:error, :cancelled})
    {:noreply, reset_state(state)}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Orchestrator paused at iteration #{state.iteration}")
    {:noreply, %{state | status: :paused}}
  end

  # ============================================================================
  # Async Approval Response Handler (Non-Blocking Consent Gate)
  # ============================================================================

  @impl true
  def handle_info({:approval_response, approval_id, result}, state) do
    # Verify this is for our pending approval
    case state.pending_approval do
      %{approval_id: ^approval_id, tool: tool_name, params: params, response: response} ->
        Logger.info("Received approval response for #{tool_name}: #{inspect(result)}")

        # Clear pending approval state
        state = %{state | pending_approval: nil, status: :thinking}

        case result do
          :approved ->
            Logger.info("Approval granted for #{tool_name}")
            # BROADCAST: Approval granted
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :approval_granted,
                approval_id: approval_id,
                tool: tool_name
              })
            end
            # Continue with tool execution
            execute_tool_direct(tool_name, params, response, state)

          :rejected ->
            Logger.info("Approval rejected for #{tool_name}")
            # BROADCAST: Approval rejected
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :approval_rejected,
                approval_id: approval_id,
                tool: tool_name
              })
            end
            handle_rejection(tool_name, params, response, state)

          {:timeout, reason} ->
            Logger.warning("Approval timeout for #{tool_name}: #{inspect(reason)}")
            # BROADCAST: Approval timeout
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :approval_timeout,
                approval_id: approval_id,
                tool: tool_name
              })
            end
            handle_timeout(tool_name, params, response, state)
        end

      _ ->
        # Stale or mismatched approval response, ignore
        Logger.warning("Received approval response for unknown/stale request: #{approval_id}")
        {:noreply, state}
    end
  end

  # ============================================================================
  # The OODA Loop via handle_continue
  # ============================================================================

  @impl true
  def handle_continue({:start, prompt, _opts}, state) do
    Logger.info("Orchestrator starting: #{String.slice(prompt, 0, 50)}...")

    # BASELINE CHECK: Know the project state before we start
    baseline_status = check_baseline(state)
    state = %{state | baseline_status: baseline_status}

    # Broadcast baseline status if dirty
    if baseline_status == :dirty and state.request_id do
      Events.broadcast(state.request_id, %{
        type: :baseline_warning,
        message: "Project has pre-existing compilation errors. Will attempt to work around them."
      })
    end

    # Route to provider
    context_meta = %{file_count: Store.stats().ast_files}
    classification = Router.route(prompt, context_meta)
    Logger.debug("Routed to: #{classification.provider}")

    # Handle native commands (no LLM)
    if classification.provider == :elixir_native do
      result = handle_native_command(prompt)
      send_reply(state, result)
      {:noreply, reset_state(state)}
    else
      # Check provider availability
      provider_module = Router.get_provider_module(classification.provider)

      provider_result =
        if Router.provider_available?(classification.provider) do
          {:ok, classification.provider, provider_module}
        else
          fallback = Router.fallback(classification.provider)
          if fallback && Router.provider_available?(fallback) do
            Logger.info("Using fallback provider: #{fallback}")
            {:ok, fallback, Router.get_provider_module(fallback)}
          else
            :no_provider
          end
        end

      case provider_result do
        {:ok, final_provider, final_module} ->
          # Build initial messages with distilled context (include baseline warning)
          messages = build_initial_messages(prompt, state, final_module)

          # Add baseline warning to messages if dirty
          messages = if baseline_status == :dirty do
            baseline_msg = %{role: "system", content: """
            WARNING: This project has pre-existing compilation errors.
            These errors existed BEFORE you started working.
            Focus on the user's request. Don't try to fix unrelated existing errors unless asked.
            """}
            [Enum.at(messages, 0), baseline_msg | Enum.drop(messages, 1)]
          else
            messages
          end

          state = %{state |
            status: :thinking,
            messages: messages,
            provider: final_provider,
            provider_module: final_module,
            iteration: 0,
            consecutive_failures: 0,
            action_history: []
          }

          {:noreply, state, {:continue, :step}}

        :no_provider ->
          send_reply(state, {:error, :no_provider_available})
          {:noreply, reset_state(state)}
      end
    end
  end

  # The main loop step
  @impl true
  def handle_continue(:step, %{status: :paused} = state) do
    # Paused - don't continue
    {:noreply, state}
  end

  @impl true
  def handle_continue(:step, %{status: :waiting_for_approval} = state) do
    # Waiting for user approval - don't continue until we receive {:approval_response, ...}
    {:noreply, state}
  end

  @impl true
  def handle_continue(:step, %{iteration: iter, max_iterations: max} = state)
      when iter >= max do
    Logger.warning("Max iterations reached (#{max})")
    send_reply(state, {:error, :max_iterations_exceeded})
    {:noreply, reset_state(state)}
  end

  @impl true
  def handle_continue(:step, %{consecutive_failures: f, max_failures: max} = state)
      when f >= max do
    Logger.warning("Max consecutive failures (#{max}), intervening...")
    {:noreply, state, {:continue, :intervene}}
  end

  @impl true
  def handle_continue(:step, state) do
    state = %{state | iteration: state.iteration + 1, status: :thinking}
    Logger.debug("OODA Loop iteration #{state.iteration}")

    # Inject distilled context before each call
    messages = inject_distilled_context(state.messages, state)

    # THINK: Call the provider
    case call_provider(%{state | messages: messages}) do
      {:ok, response} ->
        # PARSE & DECIDE
        handle_model_response(response, state)

      {:error, reason} ->
        Logger.error("Provider error: #{inspect(reason)}")
        state = %{state |
          consecutive_failures: state.consecutive_failures + 1,
          recent_errors: [reason | Enum.take(state.recent_errors, 4)]
        }
        {:noreply, state, {:continue, :step}}
    end
  end

  # Intervention step - CONTEXT PURGE
  # After repeated failures, wipe poisoned history and inject fresh truth
  @impl true
  def handle_continue(:intervene, state) do
    Logger.warning("Intervention triggered - CONTEXT PURGE")

    # Extract target file from task or recent actions
    target_file = extract_target_file(state)
    fresh_content = if target_file, do: read_fresh_content(target_file, state), else: nil

    intervention_msg = build_intervention_message(state, target_file, fresh_content)

    # Reset with fresh context - PURGE the poisoned history
    messages = [
      %{role: "system", content: Builder.build_minimal_prompt()},
      %{role: "user", content: state.task},
      %{role: "assistant", content: "I need to try a different approach."},
      %{role: "user", content: intervention_msg}
    ]

    state = %{state |
      messages: messages,
      consecutive_failures: 0,
      action_history: [],
      recent_errors: [],  # PURGE errors too
      status: :thinking
    }

    {:noreply, state, {:continue, :step}}
  end

  # HYBRID ESCALATION v2 — Senior Architect returns <action> + <payload>
  # We parse and execute DIRECTLY, bypassing the local model entirely.
  # Local model only sees: "Observation: Build is now green"
  @impl true
  def handle_continue({:escalate, _tool_name, errors}, state) do
    Logger.warning("=== HYBRID ESCALATION v2: Calling Senior Architect ===")

    # Extract the target file
    target_file = extract_target_file(state)
    file_content = if target_file, do: read_fresh_content(target_file, state), else: nil

    # Build the v2 Senior Architect prompt (requests hybrid format)
    senior_prompt = build_senior_architect_prompt_v2(target_file, file_content, errors, state)

    # BROADCAST: Escalation in progress
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :escalation_started,
        message: "Senior Architect analyzing error (v2 hybrid)..."
      })
    end

    # Call escalation provider (Groq or Gemini)
    case call_senior_architect(senior_prompt) do
      {:ok, provider_name, response_text} ->
        Logger.info("=== SENIOR ARCHITECT RESPONSE (#{provider_name}) ===")
        Logger.info(String.slice(response_text, 0, 500))

        # Try hybrid parse first (v2 protocol)
        case Parser.parse_response(response_text) do
          {:ok, %{"tool" => tool_name, "parameters" => params}} ->
            Logger.info("Senior Architect: Executing #{tool_name} directly")

            # DIRECT EXECUTION — bypass local model
            tool_opts = build_tool_opts(state)
            result = Registry.execute(tool_name, params, tool_opts)

            case result do
              {:ok, success_msg} ->
                Logger.info("SENIOR ARCHITECT FIX APPLIED: #{success_msg}")

                if state.request_id do
                  Events.broadcast(state.request_id, %{
                    type: :escalation_complete,
                    provider: provider_name,
                    message: "#{provider_name} applied #{tool_name}: #{success_msg}"
                  })
                end

                # Feed success back to local model as observation
                observation = "Observation: Senior Architect fixed the build error using #{tool_name}. Build is now green."
                messages = state.messages ++ [%{role: "user", content: observation}]
                state = %{state |
                  messages: messages,
                  escalated: true,
                  syntax_failures: 0,
                  status: :thinking
                }
                {:noreply, state, {:continue, {:verify, tool_name, result}}}

              {:error, tool_error} ->
                Logger.error("Senior Architect tool execution failed: #{inspect(tool_error)}")
                broadcast_escalation_failed(state, "Tool #{tool_name} failed: #{inspect(tool_error)}")
                # Fall through to legacy line-fix
                try_legacy_line_fix(response_text, target_file, provider_name, errors, state)
            end

          {:error, parse_reason} ->
            Logger.info("Hybrid parse failed (#{inspect(parse_reason)}), trying legacy LINE:N/CODE: format")
            try_legacy_line_fix(response_text, target_file, provider_name, errors, state)
        end

      {:error, reason} ->
        Logger.error("Senior Architect escalation failed: #{inspect(reason)}")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :escalation_failed,
            message: "Could not reach Senior Architect: #{inspect(reason)}"
          })
        end

        # Fall back to normal self-healing
        error_msg = """
        ESCALATION FAILED - Continuing with local model.

        Could not reach Senior Architect. Attempting local fix.

        COMPILER ERROR:
        #{String.slice(errors, 0, 1500)}

        INSTRUCTIONS: Use edit_file to fix the syntax error.
        """

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = %{state |
          messages: messages,
          escalated: true,
          status: :thinking
        }

        {:noreply, state, {:continue, :step}}
    end
  end

  # Legacy fallback: LINE:N / CODE: format from v1
  defp try_legacy_line_fix(response_text, target_file, provider_name, _errors, state) do
    case parse_line_fix(response_text) do
      {:ok, line_num, fixed_line} ->
        Logger.info("Legacy fix: line #{line_num} -> #{String.slice(fixed_line, 0, 50)}...")

        case apply_line_fix(target_file, line_num, fixed_line, state) do
          {:ok, result} ->
            Logger.info("LEGACY FIX APPLIED: #{result}")

            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :escalation_complete,
                provider: provider_name,
                message: "#{provider_name} fixed line #{line_num} (legacy format)"
              })
            end

            state = %{state | escalated: true, syntax_failures: 0, status: :thinking}
            {:noreply, state, {:continue, {:verify, "write_file", {:ok, result}}}}

          {:error, reason} ->
            Logger.error("Legacy line fix failed: #{inspect(reason)}")
            broadcast_escalation_failed(state, "All fix attempts failed")
            {:noreply, %{state | escalated: true, status: :thinking}, {:continue, :step}}
        end

      {:error, _reason} ->
        Logger.error("No parseable fix in Senior Architect response")
        broadcast_escalation_failed(state, "Could not parse Senior Architect response")
        {:noreply, %{state | escalated: true, status: :thinking}, {:continue, :step}}
    end
  end

  # v1 build_senior_architect_prompt removed — replaced by build_senior_architect_prompt_v2

  # Build the v2 Senior Architect prompt — requests hybrid <action> + <payload> format
  # or falls back to LINE:N/CODE: for simple fixes
  defp build_senior_architect_prompt_v2(target_file, file_content, errors, _state) do
    """
    You are the Senior Elixir Architect. Fix this compilation error.

    FILE: #{target_file || "unknown"}

    ERROR:
    #{String.slice(errors, 0, 1500)}

    CURRENT FILE (with line numbers):
    #{add_line_numbers(file_content)}

    RESPONSE FORMAT — Choose ONE:

    OPTION A (for function-level fixes — PREFERRED):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Module.Name", "function_name": "func", "arity": 2}}
    </action>

    ```elixir
    def func(arg1, arg2) do
      # your corrected function code here
    end
    ```

    OPTION B (for single-line fixes):
    LINE:NUMBER
    CODE:THE CORRECTED LINE CONTENT

    RULES:
    - Fix ONLY the compilation error, nothing else
    - For Option A: code goes in ```elixir fenced block after </action>
    - For Option A: module name must be the FULL module name (e.g., Giulia.Inference.Orchestrator)
    - For Option B: NUMBER is the line number, CODE is the exact corrected line
    - Do NOT add any text after the closing ```
    - Output ONLY the fix, no explanations
    """
  end

  # Add line numbers to file content for easier reference
  defp add_line_numbers(nil), do: "(could not read file)"
  defp add_line_numbers(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} -> "#{String.pad_leading(Integer.to_string(num), 4)}: #{line}" end)
    |> Enum.join("\n")
  end

  # v1 extract_code_block removed — no longer needed with hybrid format

  # Helper to broadcast escalation failure
  defp broadcast_escalation_failed(state, message) do
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :escalation_failed,
        message: message
      })
    end
  end

  # Parse Groq's text response: LINE:N\nCODE:...
  # No JSON = no escaping nightmares
  defp parse_line_fix(response) do
    # Clean up response - remove any markdown formatting
    cleaned = response
    |> String.replace(~r/```\w*\s*/, "")
    |> String.trim()

    # Parse LINE:N and CODE:... format
    line_match = Regex.run(~r/LINE:\s*(\d+)/i, cleaned)
    code_match = Regex.run(~r/CODE:(.*)$/im, cleaned)

    case {line_match, code_match} do
      {[_, line_str], [_, code]} ->
        line_num = String.to_integer(String.trim(line_str))
        fixed_code = code  # Keep as-is, including leading whitespace
        {:ok, line_num, fixed_code}

      {nil, _} ->
        Logger.error("No LINE: found in response: #{cleaned}")
        {:error, :no_line_number}

      {_, nil} ->
        Logger.error("No CODE: found in response: #{cleaned}")
        {:error, :no_code_content}
    end
  end

  # Apply line fix: replace line N in file with fixed content
  defp apply_line_fix(file_path, line_num, fixed_line, state) do
    tool_opts = build_tool_opts(state)
    sandbox = Keyword.get(tool_opts, :sandbox)

    # Resolve the path
    safe_path = case PathSandbox.validate(sandbox, file_path) do
      {:ok, path} -> path
      {:error, _} -> file_path  # Fallback
    end

    case File.read(safe_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        if line_num > 0 and line_num <= length(lines) do
          # Replace line at index (1-based to 0-based)
          new_lines = List.replace_at(lines, line_num - 1, fixed_line)
          new_content = Enum.join(new_lines, "\n")

          case File.write(safe_path, new_content) do
            :ok ->
              {:ok, "Line #{line_num} fixed in #{Path.basename(safe_path)}"}
            {:error, reason} ->
              {:error, "Write failed: #{inspect(reason)}"}
          end
        else
          {:error, "Invalid line number: #{line_num} (file has #{length(lines)} lines)"}
        end

      {:error, reason} ->
        {:error, "Read failed: #{inspect(reason)}"}
    end
  end

  # Call cloud provider for Senior Architect consultation (Surgical Consultant)
  # Uses Groq (Llama 3.3 70B on LPU) - blazing fast, generous free tier
  # Returns {:ok, provider_name, response} or {:error, reason}
  defp call_senior_architect(prompt) do
    messages = [
      %{role: "system", content: "You are a Senior Elixir Architect. Be precise and surgical. Output only the fix, no explanations."},
      %{role: "user", content: prompt}
    ]

    # Try Groq first (LPU speed + generous quota)
    cond do
      Giulia.Provider.Groq.available?() ->
        Logger.info("Calling Groq (Llama 3.3 70B) as Senior Architect...")
        case Giulia.Provider.Groq.chat(messages, [], timeout: 60_000) do
          {:ok, response} ->
            {:ok, "Groq Llama 3.3 70B", response.content || "No response content"}
          {:error, reason} ->
            Logger.warning("Groq failed: #{inspect(reason)}, trying Gemini fallback...")
            try_gemini_fallback(messages)
        end

      Giulia.Provider.Gemini.available?() ->
        Logger.info("Calling Gemini as Senior Architect (Groq not available)...")
        try_gemini_fallback(messages)

      true ->
        Logger.warning("No escalation provider available - check GROQ_API_KEY or GEMINI_API_KEY")
        {:error, :no_escalation_provider}
    end
  end

  defp try_gemini_fallback(messages) do
    case Giulia.Provider.Gemini.chat(messages, [], timeout: 60_000) do
      {:ok, response} ->
        {:ok, "Gemini 2.0 Flash", response.content || "No response content"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract the file we're supposed to be working on
  defp extract_target_file(state) do
    # Try to find file from task description
    task_file = extract_file_from_text(state.task)

    # Or from recent actions
    action_file = state.action_history
    |> Enum.find_value(fn
      {tool, params, _} when tool in ["read_file", "edit_file", "write_file", "write_function", "patch_function"] ->
        params["file"] || params["path"] || params[:file] || params[:path] ||
          lookup_module_file(params["module"] || params[:module])
      {_, _, _} -> nil
    end)

    task_file || action_file
  end

  defp lookup_module_file(nil), do: nil
  defp lookup_module_file(module_name) do
    case Store.find_module(module_name) do
      {:ok, %{file: file_path}} -> file_path
      :not_found -> nil
    end
  end

  defp extract_file_from_text(text) do
    case Regex.run(~r/(?:lib|test)\/[\w\/]+\.(?:ex|exs)/, text) do
      [match] -> match
      nil -> nil
    end
  end

  defp read_fresh_content(file_path, state) do
    tool_opts = build_tool_opts(state)
    case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
      {:ok, content} ->
        # Truncate for context window
        if String.length(content) > 3000 do
          String.slice(content, 0, 3000) <> "\n\n... [truncated]"
        else
          content
        end
      {:error, _} -> nil
    end
  end

  # Verification step (after write/edit) - THE AUTOMATIC GUARD
  @impl true
  def handle_continue({:verify, tool_name, result}, state) do
    Logger.info("Auto-verifying after #{tool_name}")

    # BROADCAST: Verification starting
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :verification_started,
        tool: tool_name,
        message: "Running mix compile..."
      })
    end

    # Run compile to check for errors
    tool_opts = build_tool_opts(state)
    case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
      {:ok, output} ->
        case parse_compile_result(output) do
          :success ->
            # Compilation succeeded - mark clean and continue
            Logger.info("Verification passed")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            # BROADCAST: Verification passed
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_passed,
                tool: tool_name,
                message: "Build successful"
              })
            end

            observation = """
            #{Builder.format_observation(tool_name, result)}

            ✅ BUILD GREEN. mix compile succeeded with zero errors.
            Your task is COMPLETE. Use the "respond" tool NOW to tell the user what you did.
            Do NOT make any more changes. Do NOT patch the same function again.
            """
            messages = state.messages ++ [%{role: "user", content: observation}]
            state = %{state | messages: messages, pending_verification: false}
            {:noreply, state, {:continue, :step}}

          {:warnings, warnings} ->
            # Warnings only - mark clean but inform model
            Logger.info("Verification passed with warnings")
            if state.project_pid, do: ProjectContext.mark_clean(state.project_pid)

            # BROADCAST: Verification passed with warnings
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_passed,
                tool: tool_name,
                message: "Build successful (with warnings)",
                warnings: String.slice(warnings, 0, 200)
              })
            end

            observation = """
            #{Builder.format_observation(tool_name, result)}

            ✅ BUILD GREEN. mix compile succeeded (warnings only, no errors).
            Your task is COMPLETE. Use the "respond" tool NOW to tell the user what you did.
            Do NOT make any more changes. Do NOT patch the same function again.

            Compiler warnings (pre-existing, not caused by your change):
            #{String.slice(warnings, 0, 500)}
            """
            messages = state.messages ++ [%{role: "user", content: observation}]
            state = %{state | messages: messages, pending_verification: false}
            {:noreply, state, {:continue, :step}}

          {:error, errors} ->
            # Compilation failed - mark failed and force model to fix
            # THIS IS THE SELF-HEALING TRIGGER
            Logger.warning("Verification failed - compilation error")
            if state.project_pid, do: ProjectContext.mark_verification_failed(state.project_pid)

            # Increment syntax failure counter
            new_syntax_failures = state.syntax_failures + 1
            Logger.info("Syntax failure count: #{new_syntax_failures}")

            # BROADCAST: Verification FAILED - Self-healing triggered
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :verification_failed,
                tool: tool_name,
                message: "BUILD BROKEN - Model must fix (attempt #{new_syntax_failures})",
                errors: String.slice(errors, 0, 500)
              })
            end

            # HYBRID ESCALATION CHECK
            # Escalate when combined failures reach threshold (syntax + consecutive)
            total_failures = new_syntax_failures + state.consecutive_failures
            if (new_syntax_failures >= 2 or total_failures >= 2) and not state.escalated do
              Logger.warning("HYBRID ESCALATION: Local model failed #{new_syntax_failures} times, calling Sonnet")

              # BROADCAST: Escalation triggered (provider determined at call time)
              if state.request_id do
                Events.broadcast(state.request_id, %{
                  type: :escalation_triggered,
                  message: "Calling Senior Architect for assistance..."
                })
              end

              # Store state and trigger escalation
              state = %{state |
                syntax_failures: new_syntax_failures,
                last_compile_error: errors,
                pending_verification: false
              }
              {:noreply, state, {:continue, {:escalate, tool_name, errors}}}
            else
              # Normal self-healing path
              error_msg = """
              ⚠️ SELF-HEALING MODE ACTIVATED ⚠️

              Your #{tool_name} broke the build. You MUST fix this NOW.

              COMPILER ERROR:
              #{String.slice(errors, 0, 1500)}

              INSTRUCTIONS:
              1. DO NOT use lookup_function, get_module_info, or search_code - you already know the file
              2. Use edit_file to fix the specific syntax error shown above
              3. Focus on the exact line mentioned in the error
              4. Make the minimal change needed to fix the syntax

              The file is: #{state.last_action |> elem(1) |> Map.get("file", Map.get(elem(state.last_action, 1), "module", "unknown"))}
              """

              messages = state.messages ++ [%{role: "user", content: error_msg}]
              # ITERATION BONUS: Grant +5 turns for self-healing
              new_max = state.max_iterations + 5
              state = %{state |
                messages: messages,
                pending_verification: false,
                max_iterations: new_max,
                syntax_failures: new_syntax_failures,
                last_compile_error: errors
              }
              Logger.info("Self-healing activated: max_iterations increased to #{new_max}")
              {:noreply, state, {:continue, :step}}
            end
        end

      {:error, reason} ->
        # Couldn't run compile - continue anyway with warning
        Logger.warning("Verification skipped: #{inspect(reason)}")
        observation = Builder.format_observation(tool_name, result)
        messages = state.messages ++ [%{role: "user", content: observation}]
        state = %{state | messages: messages, pending_verification: false}
        {:noreply, state, {:continue, :step}}
    end
  end

  # Parse mix compile output to determine success/warnings/errors
  defp parse_compile_result(output) do
    cond do
      # Explicit exit code failure
      String.contains?(output, "Exit code:") and not String.contains?(output, "Exit code: 0") ->
        {:error, extract_compile_errors(output)}

      # Elixir compile errors
      String.contains?(output, "** (") ->
        {:error, output}

      # Module-level errors (but NOT warnings that happen to contain "error" in text)
      Regex.match?(~r/^.*error\[.*\]|^\*\* \(|compile error/m, output) ->
        {:error, extract_compile_errors(output)}

      # Warnings only
      String.contains?(output, "warning:") ->
        {:warnings, extract_compile_warnings(output)}

      # Success
      true ->
        :success
    end
  end

  defp extract_compile_errors(output) do
    # Extract specific error lines for cleaner feedback
    specific_errors = output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "error") or
      String.contains?(line, "Error") or
      String.contains?(line, "** (") or
      String.contains?(line, "undefined") or
      String.match?(line, ~r/^\s+\|/)  # caret lines
    end)
    |> Enum.take(30)
    |> Enum.join("\n")

    # FALLBACK: If the surgical parser found nothing, send last 20 lines of raw output.
    # The model needs SOMETHING to work with for self-healing.
    if String.trim(specific_errors) == "" do
      raw_tail = output
      |> String.split("\n")
      |> Enum.take(-20)
      |> Enum.join("\n")

      "The compiler failed but I couldn't parse a specific error. Raw output (last 20 lines):\n#{raw_tail}"
    else
      specific_errors
    end
  end

  defp extract_compile_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "warning:"))
    |> Enum.take(10)
    |> Enum.join("\n")
  end

  # Check baseline project state before starting work
  # Returns :clean, :dirty, or :unknown
  defp check_baseline(state) do
    if state.project_path do
      Logger.info("Checking baseline compilation state...")
      tool_opts = build_tool_opts(state)

      case Registry.execute("run_mix", %{"command" => "compile --all-warnings"}, tool_opts) do
        {:ok, output} ->
          case parse_compile_result(output) do
            :success ->
              Logger.info("Baseline: clean")
              :clean

            {:warnings, _} ->
              Logger.info("Baseline: clean (with warnings)")
              :clean

            {:error, errors} ->
              Logger.warning("Baseline: DIRTY - pre-existing errors")
              Logger.debug("Pre-existing errors:\n#{String.slice(errors, 0, 500)}")
              :dirty
          end

        {:error, reason} ->
          Logger.warning("Baseline check failed: #{inspect(reason)}")
          :unknown
      end
    else
      :unknown
    end
  end

  # ============================================================================
  # Response Handling
  # ============================================================================

  defp handle_model_response(response, state) do
    case parse_model_response(response) do
      {:tool_call, "respond", %{"message" => message}} ->
        # Task complete!
        Logger.info("=== TASK COMPLETE ===")
        Logger.info("Iterations: #{state.iteration}")
        Logger.info("Response: #{String.slice(message, 0, 300)}")
        send_reply(state, {:ok, message})
        {:noreply, reset_state(state)}

      {:tool_call, "think", %{"thought" => thought}} ->
        # Model reasoning - log and continue, but limit consecutive thinks
        Logger.info("=== MODEL THINKING ===")
        Logger.info("Thought: #{String.slice(thought, 0, 300)}")

        # Count consecutive think calls to prevent loops
        think_count = count_recent_thinks(state.action_history)

        if think_count >= 2 do
          # Force the model to respond after 2 thinks
          Logger.warning("Too many consecutive thinks (#{think_count}), forcing respond")
          nudge_msg = "You have been thinking too long. Use respond NOW to answer the user's question based on what you know."
          messages = state.messages ++ [%{role: "user", content: nudge_msg}]
          state = %{state | messages: messages, consecutive_failures: 0}
          {:noreply, state, {:continue, :step}}
        else
          assistant_msg = response.content || Jason.encode!(%{tool: "think", parameters: %{thought: thought}})
          messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]
          # Track think in action_history
          state = %{state |
            messages: messages,
            consecutive_failures: 0,
            action_history: [{"think", %{}, :ok} | Enum.take(state.action_history, 4)]
          }
          {:noreply, state, {:continue, :step}}
        end

      {:tool_call, tool_name, params} ->
        # ACT: Execute the tool
        execute_tool(tool_name, params, response, state)

      {:text, text} ->
        # Model returned plain text - try to extract JSON
        handle_plain_text_response(text, response, state)

      {:error, {:json_escape_error, position, malformed_json}} ->
        # SELF-HEALING: Tell model to fix its JSON escaping
        Logger.info("=== JSON ESCAPE ERROR - REQUESTING RETRY ===")
        Logger.info("Error at position: #{position}")

        # Extract context around the error
        error_context = extract_error_context(malformed_json, position)

        fix_message = """
        Your tool call failed to parse as valid JSON at position #{position}.
        Error context: ...#{error_context}...

        This is likely due to unescaped characters in your Elixir code (backticks `, quotes ", or newlines).
        In JSON strings, you must escape:
        - Backticks: No escaping needed, but avoid triple backticks
        - Quotes: Use \\"
        - Newlines: Use \\n
        - Backslashes: Use \\\\

        Please re-send the SAME tool call with properly escaped JSON.
        """

        messages = state.messages ++ [%{role: "user", content: fix_message}]
        state = %{state |
          messages: messages,
          consecutive_failures: state.consecutive_failures + 1
        }

        if state.consecutive_failures >= state.max_failures do
          Logger.warning("Max JSON retries exceeded - giving up")
          {:noreply, state, {:continue, :intervene}}
        else
          Logger.info("Retrying after JSON escape error (attempt #{state.consecutive_failures})")
          {:noreply, state, {:continue, :step}}
        end

      {:error, reason} ->
        Logger.warning("Failed to parse response: #{inspect(reason)}")
        state = %{state | consecutive_failures: state.consecutive_failures + 1}
        {:noreply, state, {:continue, :step}}
    end
  end

  # Extract context around a JSON parse error position
  defp extract_error_context(json, position) do
    start_pos = max(0, position - 30)
    end_pos = min(String.length(json), position + 30)
    String.slice(json, start_pos, end_pos - start_pos)
  end

  defp execute_tool(tool_name, params, response, state) do
    current_action = {tool_name, params}

    # Loop detection
    if current_action == state.last_action do
      Logger.warning("Same action repeated - intervening")
      {:noreply, state, {:continue, :intervene}}
    else
      # GUARD: Block edit_file after a failed patch_function on the same module.
      # The model CANNOT fix AST surgery with search-and-replace — it will corrupt the file.
      if edit_file_after_patch_failure?(tool_name, state) do
        handle_blocked_edit_file(params, response, state)
      else
        # Pre-flight check: catch obviously broken calls before approval
        case preflight_check(tool_name, params) do
          :ok ->
            # Check if tool requires approval (interactive consent gate)
            if requires_approval?(tool_name, params, state) do
              execute_with_approval(tool_name, params, response, state)
            else
              execute_tool_direct(tool_name, params, response, state)
            end

          {:error, preflight_error} ->
            # Don't bother user with approval for broken calls
            Logger.warning("Preflight failed for #{tool_name}: #{preflight_error}")
            handle_preflight_failure(tool_name, params, preflight_error, response, state)
        end
      end
    end
  end

  # Check if model is trying edit_file right after a failed patch_function
  defp edit_file_after_patch_failure?("edit_file", %{action_history: [{last_tool, _, {:error, _}} | _]})
       when last_tool in ["patch_function", "write_function"] do
    true
  end
  defp edit_file_after_patch_failure?(_, _), do: false

  # Block edit_file and force a read_file reset instead
  defp handle_blocked_edit_file(params, response, state) do
    _file = params["file"] || params["path"] || "the target file"
    Logger.warning("BLOCKED: edit_file after patch_function failure — forcing read_file reset")

    error_msg = """
    BLOCKED: You cannot use edit_file right after patch_function failed.
    The file has NOT been modified (patch_function is atomic — it aborts on error).

    Your code had a syntax error. To fix it:
    1. Use read_file to see the CURRENT (unchanged) file
    2. Fix the syntax error in your code
    3. Use patch_function again with corrected code

    Do NOT use edit_file — use patch_function for function replacement.
    """

    assistant_msg = response.content || ""
    messages = state.messages ++ [
      %{role: "assistant", content: assistant_msg},
      %{role: "user", content: error_msg}
    ]

    state = %{state |
      messages: messages,
      action_history: [{"edit_file", params, {:error, :blocked_after_patch}} | Enum.take(state.action_history, 4)]
    }

    {:noreply, state, {:continue, :step}}
  end

  # Pre-flight validation: catch obviously broken tool calls before approval
  defp preflight_check(tool_name, params) when tool_name in ["patch_function", "write_function"] do
    code = params["code"] || params[:code]
    if code && String.trim(code) != "" do
      :ok
    else
      {:error, :missing_code}
    end
  end
  defp preflight_check(_tool_name, _params), do: :ok

  # Handle preflight failure: tell model what went wrong without bothering user
  defp handle_preflight_failure(tool_name, params, :missing_code, response, state) do
    func_name = params["function_name"] || "func"
    module = params["module"] || "Module"
    arity = params["arity"] || 0

    error_msg = """
    TOOL CALL REJECTED: #{tool_name} requires code but you didn't provide any.

    You sent <action> but NO CODE after </action>. This will always fail.
    You MUST place the new function code in a ```elixir fenced block after </action>.

    CORRECT FORMAT:
    <action>
    {"tool": "#{tool_name}", "parameters": {"module": "#{module}", "function_name": "#{func_name}", "arity": #{arity}}}
    </action>

    ```elixir
    def #{func_name}(...) do
      # your new code here
    end
    ```

    The code goes in a ```elixir block after </action>, NOT inside JSON.
    Do NOT add any text after the closing ```. Try again.
    """

    assistant_msg = response.content || ""
    messages = state.messages ++ [
      %{role: "assistant", content: assistant_msg},
      %{role: "user", content: error_msg}
    ]

    state = %{state |
      messages: messages,
      action_history: [{tool_name, params, {:error, :missing_code}} | Enum.take(state.action_history, 4)],
      consecutive_failures: state.consecutive_failures + 1
    }

    {:noreply, state, {:continue, :step}}
  end

  # Execute tool that requires user approval (NON-BLOCKING)
  # Enters :waiting_for_approval state and returns immediately.
  # The OODA loop resumes when we receive {:approval_response, ...} in handle_info.
  defp execute_with_approval(tool_name, params, response, state) do
    Logger.info("Tool #{tool_name} requires approval - entering wait state")

    # Generate preview (diff for edit, content preview for write)
    preview = generate_preview(tool_name, params, state)
    # Use URL-safe approval ID (reference contains <> which break URL routing)
    approval_id = "approval-#{:erlang.phash2(state.request_id)}-#{state.iteration}"

    # BROADCAST: Tool requires approval
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_requires_approval,
        approval_id: approval_id,
        iteration: state.iteration,
        tool: tool_name,
        params: sanitize_params_for_broadcast(params),
        preview: preview
      })
    end

    # Request approval ASYNC - does not block!
    # We'll receive {:approval_response, approval_id, result} in handle_info
    Approval.request_approval_async(
      approval_id,
      tool_name,
      params,
      preview,
      self(),  # callback to this process
      timeout: 300_000
    )

    # Store pending approval context and enter waiting state
    pending = %{
      approval_id: approval_id,
      tool: tool_name,
      params: params,
      response: response
    }

    state = %{state |
      status: :waiting_for_approval,
      pending_approval: pending
    }

    # Return without continuing - we'll resume in handle_info
    {:noreply, state}
  end

  # Execute tool directly (no approval needed or already approved)
  defp execute_tool_direct(tool_name, params, response, state) do
    current_action = {tool_name, params}

    # BROADCAST: Tool call starting (only if we have a request_id)
    if state.request_id do
      Logger.info("OODA BROADCAST: tool_call #{tool_name} to #{state.request_id}")
      Events.broadcast(state.request_id, %{
        type: :tool_call,
        iteration: state.iteration,
        tool: tool_name,
        params: sanitize_params_for_broadcast(params)
      })
    end

    Logger.info("=== TOOL CALL [#{state.iteration}] ===")
    Logger.info("Tool: #{tool_name}")
    Logger.info("Params: #{inspect(params, pretty: true, limit: 500)}")

    # EXECUTE - pass project context to tools
    tool_opts = build_tool_opts(state)
    result = Registry.execute(tool_name, params, tool_opts)

    # Log and broadcast the result
    result_preview = case result do
      {:ok, data} when is_binary(data) -> String.slice(data, 0, 200)
      {:ok, data} -> inspect(data, pretty: true, limit: 200)
      {:error, reason} -> "ERROR: #{inspect(reason)}"
      other -> inspect(other, limit: 200)
    end
    Logger.info("Result: #{result_preview}")
    Logger.info("=== END TOOL CALL ===")

    # AUTO READ-BACK: On edit/write failure, auto-inject fresh file content
    # This prevents the model from spiraling - it can see the ACTUAL file state
    result = maybe_inject_readback(tool_name, params, result, tool_opts)

    # BROADCAST: Tool result (only if we have a request_id)
    if state.request_id do
      Logger.info("OODA BROADCAST: tool_result #{tool_name} to #{state.request_id}")
      Events.broadcast(state.request_id, %{
        type: :tool_result,
        tool: tool_name,
        success: match?({:ok, _}, result),
        preview: result_preview
      })
    end

    # Record in history
    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})
    messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]

    state = %{state |
      messages: messages,
      last_action: current_action,
      action_history: [{tool_name, params, result} | Enum.take(state.action_history, 4)],
      consecutive_failures: 0
    }

    # VERIFY: Auto-compile after write operations
    if tool_name in @write_tools do
      {:noreply, %{state | pending_verification: true}, {:continue, {:verify, tool_name, result}}}
    else
      # OBSERVE: Feed result back
      observation = Builder.format_observation(tool_name, result)
      messages = state.messages ++ [%{role: "user", content: observation}]
      {:noreply, %{state | messages: messages}, {:continue, :step}}
    end
  end

  # Handle rejected approval - inform model and continue
  defp handle_rejection(tool_name, params, response, state) do
    rejection_msg = """
    USER REJECTED: Your proposed #{tool_name} was rejected by the user.

    They declined the following change:
    #{format_params_brief(params)}

    Please propose a different approach or use 'respond' to ask the user for clarification.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})
    messages = state.messages ++ [
      %{role: "assistant", content: assistant_msg},
      %{role: "user", content: rejection_msg}
    ]

    state = %{state |
      messages: messages,
      action_history: [{tool_name, params, {:error, :rejected}} | Enum.take(state.action_history, 4)],
      consecutive_failures: 0
    }

    {:noreply, state, {:continue, :step}}
  end

  # Handle approval timeout
  defp handle_timeout(tool_name, params, response, state) do
    timeout_msg = """
    APPROVAL TIMEOUT: No response received for #{tool_name}.

    The user did not respond to the approval request in time.
    Please use 'respond' to inform the user that approval is needed for this change.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})
    messages = state.messages ++ [
      %{role: "assistant", content: assistant_msg},
      %{role: "user", content: timeout_msg}
    ]

    state = %{state |
      messages: messages,
      action_history: [{tool_name, params, {:error, :timeout}} | Enum.take(state.action_history, 4)],
      consecutive_failures: 0
    }

    {:noreply, state, {:continue, :step}}
  end

  # Check if a tool requires user approval.
  # Read-only tools (lookup, read, search, think, respond) are auto-approved
  # to keep the OODA loop fast. Only write tools need human consent.
  # run_mix is auto-approved for compile (verification), but requires approval
  # for test/deps/other commands that have side effects.
  defp requires_approval?("run_mix", params, _state) do
    command = params["command"] || params[:command] || ""
    command not in ["compile", "help"]
  end

  defp requires_approval?(tool_name, _params, _state) do
    tool_name in @write_tools
  end

  # Generate a preview for the approval request
  defp generate_preview(tool_name, params, state) do
    case tool_name do
      "write_file" ->
        generate_write_preview(params, state)

      "edit_file" ->
        generate_edit_preview(params, state)

      "write_function" ->
        generate_function_preview(params, state)

      "patch_function" ->
        generate_function_preview(params, state)

      _ ->
        "Tool: #{tool_name}\nParams: #{inspect(params, pretty: true, limit: 500)}"
    end
  end

  defp generate_write_preview(params, state) do
    path = params["path"] || params[:path]
    content = params["content"] || params[:content] || ""

    # Resolve the path to check if file exists
    resolved_path = resolve_tool_path(path, state)

    case File.read(resolved_path) do
      {:ok, existing_content} ->
        # File exists - show diff
        Diff.colorized(existing_content, content, file_path: path)

      {:error, :enoent} ->
        # New file - show preview
        Diff.preview_new(content, file_path: path)

      {:error, _} ->
        # Can't read - just show content preview
        Diff.preview_new(content, file_path: path)
    end
  end

  defp generate_edit_preview(params, state) do
    file = params["file"] || params[:file]
    old_text = params["old_text"] || params[:old_text] || ""
    new_text = params["new_text"] || params[:new_text] || ""

    # Resolve the path
    resolved_path = resolve_tool_path(file, state)

    case File.read(resolved_path) do
      {:ok, content} ->
        # Show what the edit would do
        if String.contains?(content, old_text) do
          new_content = String.replace(content, old_text, new_text, global: false)
          Diff.colorized(content, new_content, file_path: file)
        else
          "File: #{file}\n\nold_text not found in file:\n#{String.slice(old_text, 0, 200)}"
        end

      {:error, _} ->
        "File: #{file}\n\nCould not read file to generate preview."
    end
  end

  defp generate_function_preview(params, state) do
    module = params["module"] || params[:module]
    func_name = params["function_name"] || params[:function_name]
    arity = params["arity"] || params[:arity]
    new_code = params["code"] || params[:code] || ""

    # Look up the module to find its file
    case Store.find_module(module) do
      {:ok, %{file: file_path}} ->
        resolved = resolve_tool_path(file_path, state)
        case File.read(resolved) do
          {:ok, content} ->
            # Try to extract the old function for a proper diff
            old_code = extract_old_function(content, func_name, arity)

            if old_code do
              diff = Diff.colorized(old_code, new_code, file_path: Path.basename(file_path))
              """
              Module: #{module}
              Function: #{func_name}/#{arity}
              File: #{Path.basename(file_path)}

              #{diff}
              """
            else
              """
              Module: #{module}
              Function: #{func_name}/#{arity} (new)
              File: #{Path.basename(file_path)}

              === NEW FUNCTION CODE ===
              #{new_code}
              """
            end

          {:error, _} ->
            "Module: #{module}\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
        end

      :not_found ->
        "Module: #{module} (not found in index)\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
    end
  end

  # Extract the current function source from file content using Sourceror.
  # Returns the old function code as a string, or nil if not found.
  defp extract_old_function(content, func_name, arity) do
    source = String.replace(content, "\r\n", "\n")
    func_atom = String.to_atom(func_name)
    arity = if is_binary(arity), do: String.to_integer(arity), else: arity

    case Sourceror.parse_string(source) do
      {:ok, {:defmodule, _meta, [_alias, [do: body]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      {:ok, {:defmodule, _meta, [_alias, [{_do_key, body}]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_function_from_body(source, {:__block__, _meta, statements}, func_atom, arity) do
    ranges = Enum.flat_map(statements, fn stmt ->
      case match_func_def(stmt, func_atom, arity) do
        {:ok, range} -> [range]
        _ -> []
      end
    end)

    case ranges do
      [] -> nil
      [first | _] ->
        last = List.last(ranges)
        lines = String.split(source, "\n")
        end_line = min(last.end_line || length(lines), length(lines))
        lines
        |> Enum.slice((first.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")
    end
  end

  defp extract_function_from_body(source, stmt, func_atom, arity) do
    case match_func_def(stmt, func_atom, arity) do
      {:ok, range} ->
        lines = String.split(source, "\n")
        end_line = min(range.end_line || length(lines), length(lines))
        lines
        |> Enum.slice((range.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")
      _ -> nil
    end
  end

  defp match_func_def({def_type, meta, [{:when, _, [{name, _, args} | _]} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def({def_type, meta, [{name, _, args} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def(_, _, _), do: :no_match

  defp resolve_tool_path(path, state) do
    if state.project_path do
      sandbox = PathSandbox.new(state.project_path)
      case PathSandbox.validate(sandbox, path) do
        {:ok, resolved} -> resolved
        {:error, _} -> path
      end
    else
      path
    end
  end

  # Sanitize params for broadcasting (truncate large content)
  defp sanitize_params_for_broadcast(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} ->
      if is_binary(v) and byte_size(v) > 500 do
        {k, String.slice(v, 0, 500) <> "... (truncated)"}
      else
        {k, v}
      end
    end)
    |> Map.new()
  end
  defp sanitize_params_for_broadcast(params), do: params

  defp handle_plain_text_response(text, response, state) do
    case StructuredOutput.extract_json(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, _parsed} ->
            handle_model_response(%{response | content: json}, state)
          {:error, _} ->
            # Accept as final response after cleanup
            send_reply(state, {:ok, clean_model_output(text)})
            {:noreply, reset_state(state)}
        end
      {:error, _} ->
        # Plain text - accept as response after cleanup
        send_reply(state, {:ok, clean_model_output(text)})
        {:noreply, reset_state(state)}
    end
  end

  # Clean up model output that contains internal tokens or malformed data
  defp clean_model_output(text) do
    text
    # Remove common model internal tokens
    |> String.replace(~r/<\|im_start\|>.*?(<\|im_end\|>)?/s, "")
    |> String.replace(~r/<\|im_end\|>/, "")
    |> String.replace(~r/<action>.*?<\/action>/s, "")
    |> String.replace(~r/<action>.*$/s, "")  # Unclosed action tag
    |> String.replace(~r/<\/?think>/s, "")
    # Trim whitespace
    |> String.trim()
    # If nothing left, return a fallback message
    |> case do
      "" -> "I wasn't able to formulate a proper response. Please try rephrasing your request."
      cleaned -> cleaned
    end
  end

  # ============================================================================
  # Context Building - The "Distilled" Strategy
  # ============================================================================

  defp build_initial_messages(prompt, state, provider_module) do
    constitution = get_constitution(state.project_pid)
    minimal = provider_module == Giulia.Provider.LMStudio

    # Get project context
    project_summary = Store.project_summary()
    cwd = get_working_directory(state)

    opts = [
      constitution: constitution,
      minimal: minimal,
      project_summary: project_summary,
      cwd: cwd
    ]

    Builder.build_messages(prompt, opts)
  end

  defp inject_distilled_context(messages, state) do
    # Only inject if we have action history (not first iteration)
    if state.action_history == [] do
      messages
    else
      # Build context reminder
      context = build_context_reminder(state)

      # Append to last user message or add new one
      case List.last(messages) do
        %{role: "user", content: content} ->
          List.replace_at(messages, -1, %{role: "user", content: content <> "\n\n" <> context})

        _ ->
          messages ++ [%{role: "user", content: context}]
      end
    end
  end

  defp build_context_reminder(state) do
    # Last 3 actions
    recent_actions = state.action_history
    |> Enum.take(3)
    |> Enum.map(fn {tool, params, result} ->
      status = case result do
        {:ok, _} -> "OK"
        {:error, _} -> "FAILED"
      end
      "- #{tool}(#{format_params_brief(params)}) -> #{status}"
    end)
    |> Enum.join("\n")

    # Current state
    modules_count = length(Store.list_modules())

    """
    [CONTEXT REMINDER]
    Iteration: #{state.iteration}/#{state.max_iterations}
    Indexed modules: #{modules_count}
    Recent actions:
    #{recent_actions}
    """
  end

  defp count_recent_thinks(action_history) do
    action_history
    |> Enum.take_while(fn {tool, _, _} -> tool == "think" end)
    |> length()
  end

  defp format_params_brief(params) when is_map(params) do
    params
    |> Enum.take(2)
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v), do: String.slice(v, 0, 20), else: inspect(v)
      "#{k}: #{v_str}"
    end)
    |> Enum.join(", ")
  end

  defp get_working_directory(state) do
    if state.project_path do
      # Map back to host path for display
      PathMapper.to_host(state.project_path)
    else
      File.cwd!()
    end
  end

  # ============================================================================
  # Intervention
  # ============================================================================

  defp build_intervention_message(state, target_file, fresh_content) do
    error_summary = state.recent_errors
    |> Enum.take(3)
    |> Enum.map(&"- #{inspect(&1)}")
    |> Enum.join("\n")

    action_summary = state.action_history
    |> Enum.take(3)
    |> Enum.map(fn {tool, params, _} -> "- #{tool}: #{format_params_brief(params)}" end)
    |> Enum.join("\n")

    # Build fresh content section if available
    fresh_section = if target_file && fresh_content do
      """

      === CONTEXT PURGE: Fresh file content ===
      Target file: #{target_file}

      #{fresh_content}
      === END FRESH CONTENT ===

      The above is the CURRENT state of the file. Your previous attempts may have been based on stale data.
      """
    else
      ""
    end

    """
    INTERVENTION: You appear to be stuck in a loop. Your context has been PURGED.

    Recent errors:
    #{if error_summary == "", do: "(none)", else: error_summary}

    Recent actions:
    #{if action_summary == "", do: "(none)", else: action_summary}
    #{fresh_section}
    AGENTIC MANDATE: You are the developer. DO NOT ask the user to fix it.
    Use patch_function (for whole functions) or edit_file (for small fixes). Goal: GREEN BUILD.

    INSTRUCTIONS:
    1. Look at the fresh file content above (if provided)
    2. Identify the EXACT syntax error (missing end, unclosed string, etc.)
    3. For function replacement: use patch_function with code in ```elixir block after </action>
    4. For small edits: use edit_file with the EXACT old_text from the file
    5. If you cannot complete the task, use respond to explain why
    """
  end

  # ============================================================================
  # Native Commands (No LLM)
  # ============================================================================

  defp handle_native_command(prompt) do
    prompt_lower = String.downcase(prompt)

    cond do
      String.contains?(prompt_lower, "module") ->
        modules = Store.list_modules()
        list = Enum.map_join(modules, "\n", &"- #{&1.name} (#{&1.file})")
        {:ok, "Indexed modules:\n#{list}"}

      String.contains?(prompt_lower, "function") ->
        functions = Store.list_functions()
        list = functions
        |> Enum.take(20)
        |> Enum.map_join("\n", &"- #{&1.module}.#{&1.name}/#{&1.arity}")
        {:ok, "Functions (first 20):\n#{list}"}

      String.contains?(prompt_lower, "status") ->
        stats = Store.stats()
        {:ok, "Index: #{stats.ast_files} files, #{stats.total_entries} entries"}

      String.contains?(prompt_lower, "summary") ->
        {:ok, Store.project_summary()}

      true ->
        {:ok, "Native command not recognized. Ask about modules, functions, status, or summary."}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_model_response(%{content: nil}), do: {:error, :empty_response}

  defp parse_model_response(%{content: content}) when is_binary(content) do
    # Log raw model output for debugging
    Logger.info("Raw model response: #{String.slice(content, 0, 300)}")

    # Try hybrid parser first when <payload> or <action> tags are present
    if Parser.hybrid_format?(content) or String.contains?(content, "<action>") do
      case Parser.parse_response(content) do
        {:ok, %{"tool" => tool, "parameters" => params}} ->
          Logger.info("Parsed via hybrid Parser: tool=#{tool}")
          {:tool_call, tool, params}

        {:error, reason} ->
          Logger.warning("Hybrid parse failed (#{inspect(reason)}), falling back to JSON path")
          parse_model_response_json(content)
      end
    else
      parse_model_response_json(content)
    end
  end

  defp parse_model_response(%{tool_calls: [tc | _]}) do
    {:tool_call, tc.name, tc.arguments}
  end

  defp parse_model_response(_), do: {:error, :unknown_response_format}

  # JSON-only parsing path (original logic, extracted for reuse)
  defp parse_model_response_json(content) do
    case StructuredOutput.extract_json(content) do
      {:ok, json} ->
        # Trim and clean JSON before decode
        clean_json = String.trim(json)
        Logger.info("Extracted JSON (#{byte_size(clean_json)} bytes): #{clean_json}")
        case Jason.decode(clean_json) do
          {:ok, %{"tool" => tool, "parameters" => params}} ->
            {:tool_call, tool, params}
          {:ok, %{"tool" => tool}} ->
            # Model didn't include parameters - log warning
            Logger.warning("Tool call missing parameters: #{tool}")
            {:tool_call, tool, %{}}
          {:ok, decoded} ->
            Logger.warning("Invalid tool format: #{inspect(decoded)}")
            {:error, :invalid_tool_format}
          {:error, %Jason.DecodeError{position: pos} = decode_error} ->
            # JSON decode failed - return structured error for self-healing retry
            Logger.warning("JSON decode error at position #{pos}: #{inspect(decode_error)}")
            {:error, {:json_escape_error, pos, clean_json}}
          {:error, decode_error} ->
            Logger.warning("JSON decode error: #{inspect(decode_error)}")
            {:error, {:json_decode_error, decode_error}}
        end
      {:error, reason} ->
        Logger.debug("No JSON found: #{inspect(reason)}")
        {:text, content}
    end
  end

  defp call_provider(%{provider_module: module, messages: messages}) do
    tools = Registry.list_tools()
    # 120 second timeout for complex multi-turn conversations
    module.chat(messages, tools, timeout: 300_000)
  end

  defp get_constitution(nil), do: nil
  defp get_constitution(pid) when is_pid(pid) do
    try do
      ProjectContext.get_constitution(pid)
    catch
      :exit, _ -> nil
    end
  end

  defp send_reply(%{reply_to: nil}, _result), do: :ok
  defp send_reply(%{reply_to: {:async, pid}}, result) do
    send(pid, {:orchestrator_result, result})
  end
  defp send_reply(%{reply_to: from}, result) do
    GenServer.reply(from, result)
  end

  defp reset_state(state) do
    # Save trace before resetting (for debugging via /api/agent/last_trace)
    if state.task do
      trace = Trace.from_orchestrator_state(state)
      Trace.store(trace)
    end

    %{state |
      task: nil,
      status: :idle,
      messages: [],
      reply_to: nil,
      iteration: 0,
      consecutive_failures: 0,
      last_action: nil,
      action_history: [],
      recent_errors: [],
      final_response: nil,
      pending_verification: false
    }
  end

  defp build_tool_opts(state) do
    opts = []

    # Add project path for tools like run_mix
    opts = if state.project_path do
      Keyword.put(opts, :project_path, state.project_path)
    else
      opts
    end

    # Add project pid for dirty state tracking
    opts = if state.project_pid do
      Keyword.put(opts, :project_pid, state.project_pid)
    else
      opts
    end

    # Add sandbox for file operations
    opts = if state.project_path do
      sandbox = Giulia.Core.PathSandbox.new(state.project_path)
      Keyword.put(opts, :sandbox, sandbox)
    else
      opts
    end

    opts
  end

  # ============================================================================
  # Auto Read-Back on Tool Failure
  # ============================================================================

  # When an edit/write tool fails, automatically read the file and attach
  # its content to the error. This prevents the model from spiraling by
  # giving it the ACTUAL current state of the file.
  defp maybe_inject_readback(tool_name, params, {:error, reason} = original_error, tool_opts)
       when tool_name in ["edit_file", "write_function", "patch_function"] do
    # Extract file path from params
    file_path = get_file_path_from_params(tool_name, params)

    if file_path do
      case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
        {:ok, file_content} ->
          # Truncate for context window
          truncated = if String.length(file_content) > 2000 do
            String.slice(file_content, 0, 2000) <> "\n\n... [truncated, #{String.length(file_content)} bytes total]"
          else
            file_content
          end

          enhanced_error = """
          #{reason}

          === AUTO READ-BACK: Current file content ===
          #{truncated}
          === END READ-BACK ===

          Use this content to construct a correct edit_file call.
          """
          Logger.info("Auto Read-Back injected for #{file_path}")
          {:error, enhanced_error}

        {:error, read_error} ->
          Logger.warning("Auto Read-Back failed: #{inspect(read_error)}")
          original_error
      end
    else
      original_error
    end
  end

  # Pass through successes and other tools unchanged
  defp maybe_inject_readback(_tool_name, _params, result, _tool_opts), do: result

  # Extract the file path from tool params
  defp get_file_path_from_params("edit_file", params) do
    params["file"] || params[:file]
  end

  defp get_file_path_from_params("write_function", params) do
    lookup_module_file(params["module"] || params[:module])
  end

  defp get_file_path_from_params("patch_function", params) do
    lookup_module_file(params["module"] || params[:module])
  end

  defp get_file_path_from_params(_tool, _params), do: nil
end
