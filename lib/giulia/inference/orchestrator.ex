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
  alias Giulia.Inference.{Trace, Approval, Events, Transaction, RenameMFA, BulkReplace}
  alias Giulia.Utils.Diff

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Subset of write tools that are staged when transaction_mode is active
  @stageable_tools ["write_file", "edit_file", "write_function", "patch_function"]

  # Read-only tools that never modify code — loops on these need Heuristic Completion, not context purge
  @read_only_tools ~w(get_impact_map trace_path get_module_info search_code read_file
                       list_files lookup_function get_function get_context cycle_check)

  defstruct [
    # Task info
    task: nil,
    project_path: nil,
    project_pid: nil,
    reply_to: nil,
    # For event broadcasting
    request_id: nil,

    # State machine
    # :idle | :starting | :thinking | :waiting_for_approval | :paused
    status: :idle,
    messages: [],

    # Loop tracking
    iteration: 0,
    max_iterations: 50,
    consecutive_failures: 0,
    max_failures: 3,

    # History for context injection and loop detection
    last_action: nil,
    # How many times the same action was called consecutively
    repeat_count: 0,
    # Last N actions for context
    action_history: [],
    # For intervention messages
    recent_errors: [],

    # Provider
    provider: nil,
    provider_module: nil,

    # Result
    final_response: nil,

    # Verification
    pending_verification: false,

    # Test-Lock: tracks whether tests have been run and their last status
    # :untested | :red | :green
    test_status: :untested,

    # Baseline check - was project broken before we started?
    # :clean | :dirty | :unknown
    baseline_status: :unknown,

    # Approval state - for non-blocking approval flow
    # %{approval_id, tool, params, response} when waiting
    pending_approval: nil,

    # HYBRID ESCALATION - track syntax repair failures
    # Count of failed syntax repair attempts
    syntax_failures: 0,
    # Have we already called Sonnet this session?
    escalated: false,
    # Remember original provider for switching back
    original_provider: nil,
    # Store compile error for escalation context
    last_compile_error: nil,

    # Transactional Exoskeleton — staging buffer for multi-file atomic changes
    transaction: %Transaction{},

    # Multi-action queue — when model batches multiple tool calls in one response
    # [{tool_name, params}, ...] queued for sequential execution
    pending_tool_calls: [],

    # Goal Tracker — captures impact_map results to detect premature completion
    # %{module: "X", dependents: ["A", "B", ...], count: N} | nil
    last_impact_map: nil,
    # Files actually modified during this session (set of paths)
    modified_files: MapSet.new(),
    # Consecutive goal-tracker blocks (cleared when model takes action)
    goal_tracker_block_count: 0
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute synchronously. Blocks until the OODA loop completes.
  """
  def execute(orchestrator, prompt, opts \\ []) do
    # 10-minute timeout — the OODA loop can run many iterations
    GenServer.call(orchestrator, {:execute, prompt, opts}, 600_000)
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
    project_pid = Keyword.get(opts, :project_pid)

    # Read transaction preference from ProjectContext if available
    transaction_pref =
      if project_pid do
        try do
          ProjectContext.transaction_preference(project_pid)
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      else
        false
      end

    state = %__MODULE__{
      project_path: Keyword.get(opts, :project_path),
      project_pid: project_pid,
      transaction: Transaction.new(transaction_pref)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, prompt, opts}, from, state) do
    request_id = Keyword.get(opts, :request_id, make_ref() |> inspect())
    state = %{state | task: prompt, reply_to: from, status: :starting, request_id: request_id}
    {:noreply, state, {:continue, {:start, prompt, opts}}}
  end

  @impl true
  def handle_cast({:execute_async, prompt, opts, reply_pid}, state) do
    state = %{state | task: prompt, reply_to: {:async, reply_pid}, status: :starting}
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

    # Clear model tier cache so we re-detect on each new inference
    # (user may have loaded a different model in LM Studio)
    Builder.clear_model_tier_cache()

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
    context_meta = %{file_count: Store.stats(state.project_path).ast_files}
    classification = Router.route(prompt, context_meta)
    Logger.debug("Routed to: #{classification.provider}")

    # Handle native commands (no LLM)
    if classification.provider == :elixir_native do
      result = handle_native_command(prompt, state)
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
          # Detect model tier for prompt tailoring (queries LM Studio /v1/models)
          model_tier = Builder.detect_model_tier()
          detected_name = Application.get_env(:giulia, :detected_model_name, "unknown")

          if state.request_id do
            Events.broadcast(state.request_id, %{
              type: :model_detected,
              model: detected_name,
              tier: model_tier,
              message: "Model: #{detected_name} (#{model_tier} tier)"
            })
          end

          # Build initial messages with distilled context (include baseline warning)
          messages = build_initial_messages(prompt, state, final_module)

          # Add baseline warning to messages if dirty
          messages =
            if baseline_status == :dirty do
              baseline_msg = %{
                role: "system",
                content: """
                WARNING: This project has pre-existing compilation errors.
                These errors existed BEFORE you started working.
                Focus on the user's request. Don't try to fix unrelated existing errors unless asked.
                """
              }

              [Enum.at(messages, 0), baseline_msg | Enum.drop(messages, 1)]
            else
              messages
            end

          state = %{
            state
            | status: :thinking,
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
  def handle_continue(:step, %{pending_tool_calls: [next | rest]} = state) do
    # BATCHED TOOL CALL: Pop the next queued action instead of calling the LLM
    state = %{state | iteration: state.iteration + 1, pending_tool_calls: rest, status: :thinking}
    tool_name = next["tool"]
    params = next["parameters"] || %{}
    Logger.info("Multi-action queue: executing #{tool_name} (#{length(rest)} remaining)")

    # Build a synthetic response for the tool execution flow
    synthetic_content = Jason.encode!(%{tool: tool_name, parameters: params})
    synthetic_response = %{content: synthetic_content, tool_calls: nil}

    execute_tool(tool_name, params, synthetic_response, state)
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

        state = %{
          state
          | consecutive_failures: state.consecutive_failures + 1,
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

    # Detect if we're stuck in a test loop — if so, use targeted intervention
    intervention_msg =
      case state.last_action do
        {"run_tests", test_params} ->
          build_test_failure_intervention(test_params, state)

        _ ->
          target_file = extract_target_file(state)
          fresh_content = if target_file, do: read_fresh_content(target_file, state), else: nil
          build_intervention_message(state, target_file, fresh_content)
      end

    # Use correct tier prompt (not always minimal)
    model_tier = Builder.detect_model_tier()

    prompt_opts = [
      transaction_mode: state.transaction.mode,
      staged_files: Map.keys(state.transaction.staging_buffer)
    ]

    system_prompt = Builder.build_tiered_prompt(model_tier, prompt_opts)

    # If model keeps failing with patch_function, inject a tool-switch directive
    tool_switch_hint =
      case state.last_action do
        {"patch_function", _} ->
          """

          IMPORTANT: patch_function has failed repeatedly. For RENAMING function calls,
          use edit_file instead: {"tool": "edit_file", "parameters": {"file": "path", "old_text": "old", "new_text": "new"}}
          Do NOT use patch_function for renaming. Use edit_file.
          """

        _ ->
          ""
      end

    # Reset with fresh context - PURGE the poisoned history
    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: state.task},
      %{role: "assistant", content: "I need to try a different approach."},
      %{role: "user", content: intervention_msg <> tool_switch_hint}
    ]

    state = %{
      state
      | messages: messages,
        consecutive_failures: 0,
        action_history: [],
        # PURGE errors too
        recent_errors: [],
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

            # DIRECT EXECUTION — bypass local model (wrapped for safety)
            tool_opts = build_tool_opts(state)

            result =
              try do
                Registry.execute(tool_name, params, tool_opts)
              rescue
                e -> {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
              end

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
                observation =
                  "Observation: Senior Architect fixed the build error using #{tool_name}. Build is now green."

                messages = state.messages ++ [%{role: "user", content: observation}]

                state = %{
                  state
                  | messages: messages,
                    escalated: true,
                    syntax_failures: 0,
                    status: :thinking
                }

                {:noreply, state, {:continue, {:verify, tool_name, result}}}

              {:error, tool_error} ->
                Logger.error("Senior Architect tool execution failed: #{inspect(tool_error)}")

                broadcast_escalation_failed(
                  state,
                  "Tool #{tool_name} failed: #{inspect(tool_error)}"
                )

                # Fall through to legacy line-fix
                try_legacy_line_fix(response_text, target_file, provider_name, errors, state)
            end

          {:error, parse_reason} ->
            Logger.info(
              "Hybrid parse failed (#{inspect(parse_reason)}), trying legacy LINE:N/CODE: format"
            )

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
        state = %{state | messages: messages, escalated: true, status: :thinking}

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
    cleaned =
      response
      |> String.replace(~r/```\w*\s*/, "")
      |> String.trim()

    # Parse LINE:N and CODE:... format
    line_match = Regex.run(~r/LINE:\s*(\d+)/i, cleaned)
    code_match = Regex.run(~r/CODE:(.*)$/im, cleaned)

    case {line_match, code_match} do
      {[_, line_str], [_, code]} ->
        line_num = String.to_integer(String.trim(line_str))
        # Keep as-is, including leading whitespace
        fixed_code = code
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
    safe_path =
      case PathSandbox.validate(sandbox, file_path) do
        {:ok, path} -> path
        # Fallback
        {:error, _} -> file_path
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
      %{
        role: "system",
        content:
          "You are a Senior Elixir Architect. Be precise and surgical. Output only the fix, no explanations."
      },
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

  # Build a test hint for BUILD GREEN observations.
  # If a test file exists for the modified source, nudge the model to run it.
  # Also checks hub centrality to suggest regression tests for dependents.
  defp build_test_hint(state) do
    target_file = extract_target_file(state)
    direct_hint = build_direct_test_hint(target_file, state)
    regression_hint = build_regression_hint(state)

    case {direct_hint, regression_hint} do
      {"", ""} -> ""
      {d, ""} -> d
      {"", r} -> r
      {d, r} -> d <> r
    end
  end

  defp build_direct_test_hint(nil, _state), do: ""

  defp build_direct_test_hint(target_file, state) do
    test_path = Giulia.Tools.RunTests.suggest_test_file(target_file)

    resolved =
      if state.project_path do
        sandbox = PathSandbox.new(state.project_path)

        case PathSandbox.validate(sandbox, test_path) do
          {:ok, resolved} -> resolved
          {:error, _} -> nil
        end
      end

    if resolved && File.exists?(resolved) do
      "Note: Tests exist at #{test_path}. You may run them with run_tests to verify behavior.\n"
    else
      ""
    end
  end

  # Graph-driven regression hint: if we modified a hub, suggest tests for its top dependents
  defp build_regression_hint(state) do
    case state.last_action do
      {tool_name, params}
      when tool_name in ["patch_function", "write_function", "edit_file", "write_file"] ->
        module_name = resolve_module_from_params(tool_name, params, state.project_path)

        if module_name do
          case Giulia.Knowledge.Store.centrality(state.project_path, module_name) do
            {:ok, %{in_degree: in_degree, dependents: dependents}} when in_degree > 3 ->
              top_3 = Enum.take(dependents, 3)

              "HUB IMPACT: #{module_name} has #{in_degree} dependents. Consider running tests for: #{Enum.join(top_3, ", ")}\n"

            _ ->
              ""
          end
        else
          ""
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  # Extract the file we're supposed to be working on
  defp extract_target_file(state) do
    # Try to find file from task description
    task_file = extract_file_from_text(state.task)

    # Or from recent actions
    action_file =
      state.action_history
      |> Enum.find_value(fn
        {tool, params, _}
        when tool in ["read_file", "edit_file", "write_file", "write_function", "patch_function"] ->
          params["file"] || params["path"] || params[:file] || params[:path] ||
            lookup_module_file(params["module"] || params[:module], state.project_path)

        {_, _, _} ->
          nil
      end)

    task_file || action_file
  end

  defp lookup_module_file(nil, _project_path), do: nil

  defp lookup_module_file(module_name, project_path) do
    case Store.find_module(project_path, module_name) do
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

      {:error, _} ->
        nil
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
            # Compilation succeeded - mark clean
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

            # Route to auto-regression (targeted tests) before telling model "done"
            state = %{state | pending_verification: false}
            {:noreply, state, {:continue, {:auto_regress, tool_name, result, nil}}}

          {:warnings, warnings} ->
            # Warnings only - mark clean
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

            state = %{state | pending_verification: false}
            {:noreply, state, {:continue, {:auto_regress, tool_name, result, warnings}}}

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
              Logger.warning(
                "HYBRID ESCALATION: Local model failed #{new_syntax_failures} times, calling Sonnet"
              )

              # BROADCAST: Escalation triggered (provider determined at call time)
              if state.request_id do
                Events.broadcast(state.request_id, %{
                  type: :escalation_triggered,
                  message: "Calling Senior Architect for assistance..."
                })
              end

              # Store state and trigger escalation
              state = %{
                state
                | syntax_failures: new_syntax_failures,
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

              state = %{
                state
                | messages: messages,
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

  # Auto-regression step — Graph-Targeted Testing
  # After BUILD GREEN, automatically run tests for the modified module and its dependents.
  # This is the "Sniper Rifle" — not all tests, just the ones the graph says matter.
  @impl true
  def handle_continue({:auto_regress, tool_name, result, warnings}, state) do
    # Resolve which module was modified
    module_name =
      case state.last_action do
        {t, params} when t in ["patch_function", "write_function"] ->
          params["module"] || params[:module]

        {t, params} when t in ["edit_file", "write_file"] ->
          path = params["file"] || params["path"] || params[:file] || params[:path]

          case Store.find_module_by_file(state.project_path, path || "") do
            {:ok, %{name: name}} -> name
            _ -> nil
          end

        _ ->
          nil
      end

    project_path = state.project_path || File.cwd!()

    # Query the graph for test targets
    test_targets =
      if module_name do
        case Giulia.Knowledge.Store.get_test_targets(project_path, module_name) do
          {:ok, %{all_paths: paths}} when paths != [] -> paths
          _ -> []
        end
      else
        []
      end

    if test_targets != [] do
      Logger.info(
        "AUTO-REGRESSION: Running #{length(test_targets)} targeted test file(s) for #{module_name}"
      )

      # BROADCAST: Auto-regression starting
      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :auto_regression_started,
          module: module_name,
          test_files: test_targets
        })
      end

      # Run each test file and collect results
      tool_opts = build_tool_opts(state)

      test_results =
        Enum.map(test_targets, fn test_path ->
          case Giulia.Tools.RunTests.execute(%{"file" => test_path}, tool_opts) do
            {:ok, output} -> {test_path, :ok, output}
            {:error, reason} -> {test_path, :error, inspect(reason)}
          end
        end)

      # Check if any tests failed
      failures =
        Enum.filter(test_results, fn
          {_path, :ok, output} ->
            not (String.contains?(output, "0 failures") or
                   String.starts_with?(output, "ALL TESTS PASSED"))

          {_path, :error, _} ->
            true
        end)

      if failures == [] do
        # All targeted tests passed — full green
        Logger.info("AUTO-REGRESSION: All #{length(test_targets)} test files passed")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :auto_regression_passed,
            module: module_name,
            test_count: length(test_targets)
          })
        end

        test_summary =
          Enum.map_join(test_results, "\n", fn {path, _, output} ->
            "  ✅ #{path}: #{String.slice(output, 0, 80)}"
          end)

        build_green_observation(tool_name, result, warnings, state, test_summary)
      else
        # Some tests failed — model must fix the regression
        Logger.warning("AUTO-REGRESSION: #{length(failures)} test file(s) failed")
        state = %{state | test_status: :red}

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :auto_regression_failed,
            module: module_name,
            failed_count: length(failures)
          })
        end

        failure_details =
          Enum.map_join(failures, "\n\n", fn {path, _, output} ->
            "❌ #{path}:\n#{String.slice(output, 0, 800)}"
          end)

        regression_msg = """
        #{Builder.format_observation(tool_name, result)}

        ✅ BUILD GREEN — but ❌ DOWNSTREAM REGRESSION DETECTED.

        Giulia automatically verified #{length(test_targets)} test file(s) for #{module_name} and its dependents.
        #{length(failures)} file(s) have failing tests:

        #{failure_details}

        You modified a module that other code depends on. Your change broke downstream logic.
        You MUST fix the regression. Use read_file to examine the failing test, then edit_file or patch_function to fix.
        Do NOT use respond until ALL tests pass.
        """

        messages = state.messages ++ [%{role: "user", content: regression_msg}]
        # Grant extra iterations for regression fixing
        new_max = state.max_iterations + 5
        state = %{state | messages: messages, max_iterations: new_max}
        {:noreply, state, {:continue, :step}}
      end
    else
      # No test targets found — proceed with normal BUILD GREEN
      Logger.debug("AUTO-REGRESSION: No test targets found for #{module_name || "unknown"}")
      build_green_observation(tool_name, result, warnings, state, nil)
    end
  end

  # Build the final BUILD GREEN observation (shared by auto-regress pass and no-tests paths)
  defp build_green_observation(tool_name, result, warnings, state, test_summary) do
    test_hint = build_test_hint(state)

    warnings_section =
      if warnings do
        "\nCompiler warnings (pre-existing, not caused by your change):\n#{String.slice(warnings, 0, 500)}"
      else
        ""
      end

    auto_regress_section =
      if test_summary do
        "\n🎯 AUTO-REGRESSION: All targeted tests passed:\n#{test_summary}\n"
      else
        ""
      end

    observation = """
    #{Builder.format_observation(tool_name, result)}

    ✅ BUILD GREEN. mix compile succeeded.
    #{auto_regress_section}#{test_hint}Your task is COMPLETE. Use the "respond" tool NOW to tell the user what you did.
    Do NOT make any more changes. Do NOT patch the same function again.
    #{warnings_section}
    """

    messages = state.messages ++ [%{role: "user", content: observation}]
    state = %{state | messages: messages}
    {:noreply, state, {:continue, :step}}
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
    specific_errors =
      output
      |> String.split("\n")
      |> Enum.filter(fn line ->
        # caret lines
        String.contains?(line, "error") or
          String.contains?(line, "Error") or
          String.contains?(line, "** (") or
          String.contains?(line, "undefined") or
          String.match?(line, ~r/^\s+\|/)
      end)
      |> Enum.take(30)
      |> Enum.join("\n")

    # FALLBACK: If the surgical parser found nothing, send last 20 lines of raw output.
    # The model needs SOMETHING to work with for self-healing.
    if String.trim(specific_errors) == "" do
      raw_tail =
        output
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
        cond do
          # STAGING-LOCK GATE: Block respond if there are uncommitted staged changes
          state.transaction.mode and map_size(state.transaction.staging_buffer) > 0 ->
            tx = state.transaction
            lock_count = tx.lock_count + 1

            Logger.warning(
              "STAGING-LOCK: Model tried to respond with #{map_size(tx.staging_buffer)} uncommitted staged file(s) (attempt #{lock_count})"
            )

            if lock_count >= 3 do
              # Model is stuck — clear staging buffer and let it respond
              Logger.warning(
                "STAGING-LOCK: #{lock_count} consecutive blocks — clearing staging buffer to break deadlock"
              )

              Logger.info("=== TASK COMPLETE (staging-lock release) ===")
              send_reply(state, {:ok, message})

              state = %{state | transaction: Transaction.new()}

              {:noreply, reset_state(state)}
            else
              staged_list =
                tx.staging_buffer |> Map.keys() |> Enum.map_join("\n", &"  - #{&1}")

              lock_msg = """
              BLOCKED: You have uncommitted staged changes in #{map_size(tx.staging_buffer)} file(s):
              #{staged_list}

              You MUST call commit_changes before respond. Or fix your changes and try again.
              """

              messages = state.messages ++ [%{role: "user", content: lock_msg}]
              state = %{state | messages: messages, transaction: %{tx | lock_count: lock_count}}
              {:noreply, state, {:continue, :step}}
            end

          # TEST-LOCK GATE: If tests were run and are still red, block respond
          state.test_status == :red ->
            Logger.warning("TEST-LOCK: Model tried to respond but tests are still RED")

            lock_msg = """
            BLOCKED: You cannot close this task. Tests are still FAILING.
            You MUST call run_tests and get 0 failures before you can respond.
            Do NOT claim success based on a green build alone.
            DEFINITION OF DONE: build green AND tests green AND verified.
            """

            messages = state.messages ++ [%{role: "user", content: lock_msg}]
            state = %{state | messages: messages}
            {:noreply, state, {:continue, :step}}

          # GOAL TRACKER GATE: Block respond if impact_map showed dependents but most were untouched
          not is_nil(state.last_impact_map) and goal_tracker_blocks?(state) ->
            im = state.last_impact_map
            touched = MapSet.size(state.modified_files)
            block_count = state.goal_tracker_block_count + 1

            Logger.warning(
              "GOAL TRACKER: Model tried to respond after touching #{touched}/#{im.count} dependents of #{im.module} (block #{block_count})"
            )

            # Broadcast for client visibility
            if state.request_id do
              Events.broadcast(state.request_id, %{
                type: :goal_tracker_block,
                module: im.module,
                dependents: im.count,
                modified: touched
              })
            end

            if block_count >= 4 do
              # Model is stuck in a loop — release to prevent infinite cycling
              Logger.warning(
                "GOAL TRACKER: #{block_count} consecutive blocks — releasing to break deadlock"
              )

              Logger.info("=== TASK COMPLETE (goal-tracker release) ===")
              send_reply(state, {:ok, message})
              state = %{state | goal_tracker_block_count: 0}
              {:noreply, reset_state(state)}
            else
              untouched =
                im.dependents
                |> Enum.reject(fn dep ->
                  Enum.any?(
                    MapSet.to_list(state.modified_files),
                    &String.contains?(&1, module_to_path(dep))
                  )
                end)
                |> Enum.take(10)

              # Check if rename_mfa was used earlier in this session
              has_used_rename = Enum.any?(state.action_history, fn
                {:tool, "rename_mfa", _} -> true
                _ -> false
              end)

              rename_hint =
                if has_used_rename do
                  "You already used rename_mfa earlier — use it again with the CORRECT arity to rename function definitions in all implementer modules."
                else
                  "Use rename_mfa to rename function definitions across all implementers (this handles def/defp, @callback, and call sites atomically)."
                end

              lock_msg = """
              BLOCKED: You identified #{im.count} dependents of #{im.module} via get_impact_map, but you only modified #{touched} file(s).

              Untouched dependents (showing up to 10):
              #{Enum.map_join(untouched, "\n", &"  - #{&1}")}

              You MUST take action:
              1. #{rename_hint}
              2. Or use bulk_replace if you need simple string replacement across files.
              3. Or edit each remaining file individually.

              IMPORTANT: bulk_replace only matches exact strings. To rename function DEFINITIONS (def/defp), you MUST use rename_mfa.

              Do NOT call respond or think — take ACTION on the untouched files.
              """

              messages = state.messages ++ [%{role: "user", content: lock_msg}]
              state = %{state | messages: messages, goal_tracker_block_count: block_count}
              {:noreply, state, {:continue, :step}}
            end

          true ->
            # Task complete!
            Logger.info("=== TASK COMPLETE ===")
            Logger.info("Iterations: #{state.iteration}")
            Logger.info("Response: #{String.slice(message, 0, 300)}")
            send_reply(state, {:ok, message})
            {:noreply, reset_state(state)}
        end

      {:tool_call, "think", %{"thought" => thought}} ->
        # Model reasoning - log and continue, but limit consecutive thinks
        Logger.info("=== MODEL THINKING ===")
        Logger.info("Thought: #{String.slice(thought, 0, 300)}")

        # Count consecutive think calls to prevent loops
        think_count = count_recent_thinks(state.action_history)

        if think_count >= 2 do
          # Force the model to respond after 2 thinks
          Logger.warning("Too many consecutive thinks (#{think_count}), forcing respond")

          nudge_msg =
            "You have been thinking too long. Use respond NOW to answer the user's question based on what you know."

          messages = state.messages ++ [%{role: "user", content: nudge_msg}]
          state = %{state | messages: messages, consecutive_failures: 0}
          {:noreply, state, {:continue, :step}}
        else
          assistant_msg =
            response.content || Jason.encode!(%{tool: "think", parameters: %{thought: thought}})

          messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]
          # Track think in action_history
          state = %{
            state
            | messages: messages,
              consecutive_failures: 0,
              action_history: [{"think", %{}, :ok} | Enum.take(state.action_history, 4)]
          }

          {:noreply, state, {:continue, :step}}
        end

      {:multi_tool_call, tool_name, params, remaining} ->
        # BATCHED: Execute first tool, queue the rest
        Logger.info("Multi-action: executing #{tool_name}, queuing #{length(remaining)} more")
        state = %{state | pending_tool_calls: remaining}
        execute_tool(tool_name, params, response, state)

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

        state = %{
          state
          | messages: messages,
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

    # Loop detection — allow one repeat (e.g. run_tests → fix → run_tests again),
    # but intervene on the 3rd consecutive identical action
    {state, looping?} =
      if current_action == state.last_action do
        new_count = state.repeat_count + 1
        {%{state | repeat_count: new_count}, new_count >= 2}
      else
        {%{state | repeat_count: 0}, false}
      end

    if looping? do
      Logger.warning("Same action repeated #{state.repeat_count}x")

      # HEURISTIC COMPLETION: If a read-only tool is looping, the model has the data
      # but can't bring itself to call "respond". Instead of purging context (which
      # causes amnesia and re-triggers the same call), we deliver the last successful
      # observation directly to the user. The Orchestrator becomes the Deterministic
      # Supervisor — when the Probabilistic Component (LLM) fails its social step,
      # we close the loop ourselves.
      if tool_name in @read_only_tools do
        Logger.warning(
          "HEURISTIC COMPLETION: Read-only tool loop on #{tool_name}, delivering result directly"
        )

        last_observation = find_last_successful_observation(state)

        if last_observation do
          heuristic_response = """
          #{last_observation}

          ---
          _Task completed via Heuristic Completion. The model retrieved this data but entered a response loop. \
          The Orchestrator is delivering the result directly._
          """

          send_reply(state, {:ok, heuristic_response})
          {:noreply, reset_state(state)}
        else
          # No usable observation — fall back to intervention
          {:noreply, state, {:continue, :intervene}}
        end
      else
        Logger.warning("Write-tool loop — intervening with context purge")
        {:noreply, state, {:continue, :intervene}}
      end
    else
      # GUARD: Block edit_file after a failed patch_function on the same module.
      # The model CANNOT fix AST surgery with search-and-replace — it will corrupt the file.
      if edit_file_after_patch_failure?(tool_name, state) do
        handle_blocked_edit_file(params, response, state)
      else
        # TRANSACTIONAL EXOSKELETON: Auto-enable for hub modules
        state = maybe_auto_enable_transaction(tool_name, params, state)

        # Pre-flight check: catch obviously broken calls before approval
        case preflight_check(tool_name, params) do
          :ok ->
            # Check if tool requires approval (interactive consent gate)
            # When transaction_mode is active and tool is stageable, skip approval
            # (changes go to staging buffer, not disk — approval happens at commit)
            if state.transaction.mode and tool_name in @stageable_tools do
              execute_tool_direct(tool_name, params, response, state)
            else
              if requires_approval?(tool_name, params, state) do
                execute_with_approval(tool_name, params, response, state)
              else
                execute_tool_direct(tool_name, params, response, state)
              end
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
  defp edit_file_after_patch_failure?("edit_file", %{
         action_history: [{last_tool, _, {:error, _}} | _]
       })
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

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = %{
      state
      | messages: messages,
        action_history: [
          {"edit_file", params, {:error, :blocked_after_patch}}
          | Enum.take(state.action_history, 4)
        ]
    }

    {:noreply, state, {:continue, :step}}
  end

  # Pre-flight validation: catch obviously broken tool calls before approval
  defp preflight_check(tool_name, params)
       when tool_name in ["patch_function", "write_function"] do
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

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: error_msg}
        ]

    state = %{
      state
      | messages: messages,
        action_history: [
          {tool_name, params, {:error, :missing_code}} | Enum.take(state.action_history, 4)
        ],
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

    # HUB ALARM: Check centrality of the target module
    hub_warning = assess_hub_risk(tool_name, params, state.project_path)

    # Enrich preview with hub warning if applicable
    preview =
      if hub_warning do
        "#{hub_warning}\n\n#{preview}"
      else
        preview
      end

    # BROADCAST: Tool requires approval (with hub risk if applicable)
    broadcast_payload = %{
      type: :tool_requires_approval,
      approval_id: approval_id,
      iteration: state.iteration,
      tool: tool_name,
      params: sanitize_params_for_broadcast(params),
      preview: preview
    }

    # Add hub_risk field to broadcast if this is a critical hub
    broadcast_payload =
      if hub_warning do
        Map.put(broadcast_payload, :hub_risk, :high)
      else
        broadcast_payload
      end

    if state.request_id do
      Events.broadcast(state.request_id, broadcast_payload)
    end

    # Request approval ASYNC - does not block!
    # We'll receive {:approval_response, approval_id, result} in handle_info
    Approval.request_approval_async(
      approval_id,
      tool_name,
      params,
      preview,
      # callback to this process
      self(),
      timeout: 300_000
    )

    # Store pending approval context and enter waiting state
    pending = %{
      approval_id: approval_id,
      tool: tool_name,
      params: params,
      response: response
    }

    state = %{state | status: :waiting_for_approval, pending_approval: pending}

    # Return without continuing - we'll resume in handle_info
    {:noreply, state}
  end

  # Execute tool directly (no approval needed or already approved)
  defp execute_tool_direct(tool_name, params, response, state) do
    # TRANSACTIONAL EXOSKELETON: Intercept writes when staging is active
    cond do
      # Intercept commit_changes — handled entirely by orchestrator
      tool_name == "commit_changes" ->
        execute_commit_changes(params, response, state)

      # Stage write tools when transaction mode is on
      state.transaction.mode and tool_name in @stageable_tools ->
        execute_tool_staged(tool_name, params, response, state)

      # Overlay read_file with staged content when transaction mode is on
      state.transaction.mode and tool_name == "read_file" ->
        execute_read_with_overlay(params, response, state)

      # Intercept get_staged_files — return staging buffer info
      tool_name == "get_staged_files" ->
        execute_get_staged_files(response, state)

      # Intercept bulk_replace — batch find-and-replace across multiple files
      tool_name == "bulk_replace" ->
        execute_bulk_replace(params, response, state)

      # Intercept rename_mfa — AST-based function rename across codebase
      tool_name == "rename_mfa" ->
        execute_rename_mfa(params, response, state)

      # Normal execution path
      true ->
        execute_tool_normal(tool_name, params, response, state)
    end
  end

  # Normal tool execution (original execute_tool_direct logic)
  defp execute_tool_normal(tool_name, params, response, state) do
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

    # EXECUTE - pass project context to tools (wrapped in try/rescue to prevent crashes)
    tool_opts = build_tool_opts(state)

    result =
      try do
        Registry.execute(tool_name, params, tool_opts)
      rescue
        e in FunctionClauseError ->
          {:error,
           "Invalid parameters for #{tool_name}. Check required fields. Details: #{Exception.message(e)}"}

        e ->
          {:error, "Tool #{tool_name} crashed: #{Exception.message(e)}"}
      end

    # Log and broadcast the result (full content, no truncation)
    result_preview =
      case result do
        {:ok, data} when is_binary(data) -> data
        {:ok, data} -> inspect(data, pretty: true, limit: :infinity)
        {:error, reason} -> "ERROR: #{inspect(reason)}"
        other -> inspect(other, limit: :infinity)
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

    state = %{
      state
      | messages: messages,
        last_action: current_action,
        action_history: [{tool_name, params, result} | Enum.take(state.action_history, 4)],
        consecutive_failures: 0,
        goal_tracker_block_count: 0
    }

    # TEST-LOCK: Track test results for respond gate
    state =
      if tool_name == "run_tests" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            if String.contains?(result_str, "0 failures") or
                 String.starts_with?(result_str, "ALL TESTS PASSED") do
              Logger.info("TEST-LOCK: Tests are GREEN")
              %{state | test_status: :green}
            else
              Logger.info("TEST-LOCK: Tests are RED")
              %{state | test_status: :red}
            end

          _ ->
            Logger.info("TEST-LOCK: Tests are RED (error)")
            %{state | test_status: :red}
        end
      else
        state
      end

    # GOAL TRACKER: Capture impact_map results for premature completion detection
    state =
      if tool_name == "get_impact_map" do
        case result do
          {:ok, result_str} when is_binary(result_str) ->
            # Parse the downstream dependents from the impact map output
            dependents = extract_downstream_dependents(result_str)
            module = params["module"] || params[:module] || "unknown"

            if dependents != [] do
              Logger.info("GOAL TRACKER: Captured #{length(dependents)} dependents for #{module}")

              %{
                state
                | last_impact_map: %{
                    module: module,
                    dependents: dependents,
                    count: length(dependents)
                  }
              }
            else
              state
            end

          _ ->
            state
        end
      else
        state
      end

    # GOAL TRACKER: Track modified files for write operations
    state =
      if tool_name in @write_tools do
        path = params["path"] || params[:path] || params["file"] || params[:file]

        if path do
          resolved = resolve_tool_path(path, state)
          %{state | modified_files: MapSet.put(state.modified_files, resolved)}
        else
          state
        end
      else
        state
      end

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

  # ============================================================================
  # Transactional Exoskeleton — Staging Logic
  # ============================================================================

  # Execute a write tool in staged mode (buffer in memory, don't write to disk)
  defp execute_tool_staged(tool_name, params, response, state) do
    current_action = {tool_name, params}

    # BROADCAST: Staged tool call
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_call,
        iteration: state.iteration,
        tool: tool_name,
        params: sanitize_params_for_broadcast(params),
        staged: true
      })
    end

    Logger.info("=== STAGED TOOL CALL [#{state.iteration}] ===")
    Logger.info("Tool: #{tool_name} (transaction mode)")

    resolve_fn = &resolve_tool_path(&1, state)

    {result, new_tx} =
      case tool_name do
        "write_file" ->
          Transaction.stage_write(state.transaction, params, resolve_fn)

        "edit_file" ->
          Transaction.stage_edit(state.transaction, params, resolve_fn)

        tool when tool in ["patch_function", "write_function"] ->
          Transaction.stage_ast(state.transaction, tool, params,
            project_path: state.project_path,
            resolve_fn: resolve_fn,
            tool_opts: build_tool_opts(state)
          )

        _ ->
          {{:error, "Unknown stageable tool: #{tool_name}"}, state.transaction}
      end

    state = %{state | transaction: new_tx}

    # Build observation with [STAGED] prefix
    {result_preview, observation} =
      case result do
        {:ok, msg} ->
          staged_count = map_size(state.transaction.staging_buffer)

          obs =
            "[STAGED] #{tool_name}: #{msg}\nCurrently staging #{staged_count} file(s). Use commit_changes to flush to disk."

          {String.slice(msg, 0, 200), obs}

        {:error, reason} ->
          error_str = if is_binary(reason), do: reason, else: inspect(reason)
          {"ERROR: #{error_str}", "ERROR: #{tool_name} staging failed: #{error_str}"}
      end

    Logger.info("Staged result: #{result_preview}")
    Logger.info("=== END STAGED TOOL CALL ===")

    # BROADCAST: Staged result
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :tool_result,
        tool: tool_name,
        success: match?({:ok, _}, result),
        preview: result_preview,
        staged: true
      })
    end

    # Record in history
    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = %{
      state
      | messages: messages,
        last_action: current_action,
        action_history: [{tool_name, params, result} | Enum.take(state.action_history, 4)],
        consecutive_failures: 0,
        goal_tracker_block_count: 0
    }

    # No verification during staging — that happens at commit time
    {:noreply, state, {:continue, :step}}
  end

  # NOTE: stage_write_file, stage_edit_file, stage_ast_tool, backup_original,
  # and restore_disk_content have been extracted to Giulia.Inference.Transaction

  # Read file with staging overlay
  defp execute_read_with_overlay(params, response, state) do
    path = params["path"] || params[:path] || params["file"] || params[:file]
    resolved_path = resolve_tool_path(path, state)

    case Transaction.read_with_overlay(state.transaction, resolved_path) do
      nil ->
        # Not in staging buffer — proceed with normal read
        execute_tool_normal("read_file", params, response, state)

      staged_content ->
        # Return staged content with marker
        Logger.info("READ OVERLAY: Returning staged content for #{path}")

        result = {:ok, "[STAGED VERSION — not yet on disk]\n#{staged_content}"}

        # BROADCAST
        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: state.iteration,
            tool: "read_file",
            params: sanitize_params_for_broadcast(params),
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "read_file",
            success: true,
            preview: "[STAGED] #{String.slice(staged_content, 0, 100)}",
            staged: true
          })
        end

        # Record and continue
        assistant_msg =
          response.content || Jason.encode!(%{tool: "read_file", parameters: params})

        observation = Builder.format_observation("read_file", result)

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = %{
          state
          | messages: messages,
            last_action: {"read_file", params},
            action_history: [{"read_file", params, result} | Enum.take(state.action_history, 4)],
            consecutive_failures: 0
        }

        {:noreply, state, {:continue, :step}}
    end
  end

  # Intercept get_staged_files — return staging buffer contents to the model
  defp execute_get_staged_files(response, state) do
    result = {:ok, Transaction.format_staged_files(state.transaction)}

    # Record and continue
    assistant_msg =
      response.content || Jason.encode!(%{tool: "get_staged_files", parameters: %{}})

    observation = Builder.format_observation("get_staged_files", result)

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = %{
      state
      | messages: messages,
        last_action: {"get_staged_files", %{}},
        action_history: [{"get_staged_files", %{}, :ok} | Enum.take(state.action_history, 4)],
        consecutive_failures: 0
    }

    {:noreply, state, {:continue, :step}}
  end

  # ============================================================================
  # Bulk Replace — delegates to Giulia.Inference.BulkReplace (pure-functional)
  # ============================================================================

  defp execute_bulk_replace(params, response, state) do
    # Auto-enable transaction mode for bulk operations
    file_list = params["file_list"] || params[:file_list] || []

    state =
      if not state.transaction.mode and file_list != [] do
        Logger.info("BULK_REPLACE: Auto-enabling transaction mode for batch operation")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :transaction_auto_enabled,
            reason: "bulk_replace across #{length(file_list)} files"
          })
        end

        %{state | transaction: %{state.transaction | mode: true}}
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &resolve_tool_path(&1, state),
      modified_files: state.modified_files
    ]

    case BulkReplace.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: state.iteration,
            tool: "bulk_replace",
            params: %{pattern: meta.pattern, replacement: meta.replacement,
                       files: meta.file_count},
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "bulk_replace",
            success: meta.total_replacements > 0,
            preview: "#{length(meta.staged)} files staged, #{meta.total_replacements} replacements",
            staged: true
          })
        end

        assistant_msg =
          response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = %{
          state
          | transaction: new_tx,
            modified_files: modified_files,
            messages: messages,
            last_action: {"bulk_replace", params},
            action_history: [
              {"bulk_replace", params, {:ok, "staged"}} | Enum.take(state.action_history, 4)
            ],
            consecutive_failures: 0
        }

        {:noreply, state, {:continue, :step}}

      {:error, reason} ->
        send_bulk_error(reason, params, response, state)
    end
  end

  defp send_bulk_error(reason, params, response, state) do
    observation = "ERROR: bulk_replace failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "bulk_replace", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = %{state | messages: messages, consecutive_failures: state.consecutive_failures + 1}
    {:noreply, state, {:continue, :step}}
  end

  # ============================================================================
  # RenameMFA — delegates to Giulia.Inference.RenameMFA (pure-functional)
  # ============================================================================

  defp execute_rename_mfa(params, response, state) do
    # Auto-enable transaction mode for rename operations
    state =
      if not state.transaction.mode do
        module = params["module"] || params[:module]
        old_name = params["old_name"] || params[:old_name]
        arity = params["arity"] || params[:arity]
        new_name = params["new_name"] || params[:new_name]
        Logger.info("RENAME_MFA: Auto-enabling transaction mode")

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :transaction_auto_enabled,
            reason: "rename_mfa: #{module}.#{old_name}/#{arity} → #{new_name}"
          })
        end

        %{state | transaction: %{state.transaction | mode: true}}
      else
        state
      end

    opts = [
      project_path: state.project_path,
      resolve_fn: &resolve_tool_path(&1, state),
      modified_files: state.modified_files
    ]

    case RenameMFA.execute(params, state.transaction, opts) do
      {:ok, observation, new_tx, modified_files, meta} ->
        # Broadcast events
        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :tool_call,
            iteration: state.iteration,
            tool: "rename_mfa",
            params: %{module: meta.module, old_name: meta.old_name,
                       new_name: meta.new_name, arity: meta.arity},
            staged: true
          })

          Events.broadcast(state.request_id, %{
            type: :tool_result,
            tool: "rename_mfa",
            success: meta.total_changes > 0,
            preview: "#{length(meta.staged)} files, #{meta.total_changes} renames",
            staged: true
          })
        end

        assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

        messages =
          state.messages ++
            [
              %{role: "assistant", content: assistant_msg},
              %{role: "user", content: observation}
            ]

        state = %{
          state
          | transaction: new_tx,
            modified_files: modified_files,
            messages: messages,
            last_action: {"rename_mfa", params},
            action_history: [
              {"rename_mfa", params, {:ok, "staged"}} | Enum.take(state.action_history, 4)
            ],
            consecutive_failures: 0
        }

        {:noreply, state, {:continue, :step}}

      {:error, reason} ->
        send_rename_error(reason, params, response, state)
    end
  end

  defp send_rename_error(reason, params, response, state) do
    observation = "ERROR: rename_mfa failed: #{reason}"
    assistant_msg = response.content || Jason.encode!(%{tool: "rename_mfa", parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: observation}
        ]

    state = %{state | messages: messages, consecutive_failures: state.consecutive_failures + 1}
    {:noreply, state, {:continue, :step}}
  end

  # ============================================================================
  # Transactional Exoskeleton — Commit/Rollback
  # ============================================================================

  # Execute the commit_changes pseudo-tool
  defp execute_commit_changes(params, response, state) do
    if map_size(state.transaction.staging_buffer) == 0 do
      # Nothing to commit
      observation = "Nothing staged to commit. Use write_file or edit_file first."

      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages =
        state.messages ++
          [
            %{role: "assistant", content: assistant_msg},
            %{role: "user", content: observation}
          ]

      state = %{state | messages: messages, consecutive_failures: 0}
      {:noreply, state, {:continue, :step}}
    else
      # Proceed with commit via handle_continue to keep GenServer responsive
      assistant_msg =
        response.content || Jason.encode!(%{tool: "commit_changes", parameters: params})

      messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]
      state = %{state | messages: messages}
      {:noreply, state, {:continue, {:commit_changes, params}}}
    end
  end

  @impl true
  def handle_continue({:commit_changes, params}, state) do
    tx = state.transaction
    staged_files = Map.keys(tx.staging_buffer)
    file_count = length(staged_files)
    message = params["message"] || "Committing #{file_count} staged file(s)"

    Logger.info("COMMIT: #{message}")
    Logger.info("COMMIT: Flushing #{file_count} file(s) to disk")

    # BROADCAST: Commit started
    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :commit_started,
        file_count: file_count,
        files: staged_files,
        message: message
      })
    end

    # Phase 1: Ensure backups are current (re-read from disk for safety)
    tx =
      Enum.reduce(staged_files, tx, fn path, acc ->
        Transaction.backup_original(acc, path)
      end)

    state = %{state | transaction: tx}

    # Phase 2: Flush all staged files to disk
    write_results =
      Enum.map(tx.staging_buffer, fn {path, content} ->
        {path, File.write(path, content)}
      end)

    write_failures = Enum.filter(write_results, fn {_path, result} -> result != :ok end)

    if write_failures != [] do
      # Write failed — rollback
      Logger.warning("COMMIT: Write phase failed, rolling back")
      state = %{state | transaction: Transaction.rollback(state.transaction, state.project_path)}

      error_msg = "COMMIT FAILED (write phase): #{inspect(write_failures)}"

      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :commit_rollback,
          reason: "write_failure",
          files: staged_files,
          message: error_msg
        })
      end

      messages = state.messages ++ [%{role: "user", content: error_msg}]
      state = %{state | messages: messages}
      {:noreply, state, {:continue, :step}}
    else
      # Phase 3: Compile
      Logger.info("COMMIT: Compile phase")
      tool_opts = build_tool_opts(state)

      if state.request_id do
        Events.broadcast(state.request_id, %{type: :commit_compiling})
      end

      case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
        {:ok, output} ->
          case parse_compile_result(output) do
            :success ->
              Logger.info("COMMIT: Compile passed, running integrity check")

              if state.request_id do
                Events.broadcast(state.request_id, %{type: :commit_compile_passed})
              end

              commit_integrity_check(staged_files, params, state)

            {:warnings, _warnings} ->
              Logger.info("COMMIT: Compile passed with warnings, running integrity check")

              if state.request_id do
                Events.broadcast(state.request_id, %{type: :commit_compile_passed, warnings: true})
              end

              commit_integrity_check(staged_files, params, state)

            {:error, errors} ->
              # Compile failed — rollback
              Logger.warning("COMMIT: Compile failed, rolling back")
              state = %{state | transaction: Transaction.rollback(state.transaction, state.project_path)}

              error_msg = """
              COMMIT FAILED: Compilation errors after flushing staged changes. All changes have been ROLLED BACK.
              All #{length(staged_files)} files are back to their ORIGINAL state. Your staging buffer is cleared.

              COMPILER ERRORS:
              #{String.slice(errors, 0, 1500)}

              POST-ROLLBACK REALITY CHECK:
              Your previous plan was INCONSISTENT. The most common cause is renaming function DEFINITIONS
              without also renaming CALL SITES (or vice versa). In your next transaction, you MUST:
              1. Rename DEFINITIONS (def old_name → def new_name) in all tool/module files
              2. Rename CALL SITES (Module.old_name → Module.new_name) in all callers
              3. Rename any @callback declarations if applicable
              4. Stage ALL of these changes BEFORE calling commit_changes
              Use bulk_replace multiple times — once per pattern — before committing.
              """

              if state.request_id do
                Events.broadcast(state.request_id, %{
                  type: :commit_rollback,
                  reason: "compile_failure",
                  message: "Compilation failed — all changes rolled back",
                  files: staged_files,
                  errors: String.slice(errors, 0, 500)
                })
              end

              messages = state.messages ++ [%{role: "user", content: error_msg}]
              state = %{state | messages: messages}
              {:noreply, state, {:continue, :step}}
          end

        {:error, reason} ->
          # Couldn't run compile — rollback to be safe
          Logger.warning("COMMIT: Could not run compile: #{inspect(reason)}, rolling back")
          state = %{state | transaction: Transaction.rollback(state.transaction, state.project_path)}

          error_msg =
            "COMMIT FAILED: Could not verify compilation: #{inspect(reason)}. Changes rolled back. Staging buffer cleared."

          messages = state.messages ++ [%{role: "user", content: error_msg}]
          state = %{state | messages: messages}
          {:noreply, state, {:continue, :step}}
      end
    end
  end

  # Integrity check phase — between compile and auto-regression.
  # Re-indexes modified files, rebuilds the knowledge graph, then checks
  # that all behaviours and their implementers agree on function names.
  defp commit_integrity_check(staged_files, params, state) do
    # Re-index modified .ex/.exs files so ETS is fresh
    staged_files
    |> Enum.filter(fn path ->
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")
    end)
    |> Enum.each(&Giulia.Context.Indexer.scan_file/1)

    # Small delay for async scan_file casts to complete
    Process.sleep(500)

    # Rebuild knowledge graph with fresh data
    Giulia.Knowledge.Store.rebuild(state.project_path, Giulia.Context.Store.all_asts(state.project_path))

    # Check all behaviour-implementer contracts
    if state.request_id do
      Events.broadcast(state.request_id, %{type: :commit_integrity_checking})
    end

    case Giulia.Knowledge.Store.check_all_behaviours(state.project_path) do
      {:ok, :consistent} ->
        Logger.info("COMMIT: Integrity check passed, running auto-regression")

        if state.request_id do
          Events.broadcast(state.request_id, %{type: :commit_integrity_passed})
        end

        commit_auto_regress(staged_files, params, state)

      {:error, fractures} ->
        Logger.warning("COMMIT: Integrity check FAILED — architectural fracture detected")
        state = %{state | transaction: Transaction.rollback(state.transaction, state.project_path)}

        report = Transaction.format_fracture_report(fractures)

        error_msg = """
        COMMIT FAILED: ARCHITECTURAL FRACTURE — behaviour-implementer mismatch detected.
        All #{length(staged_files)} files have been ROLLED BACK to their original state.

        #{report}

        POST-ROLLBACK REALITY CHECK:
        Your changes compiled (syntax OK) but fractured the architecture (semantics BROKEN).
        A behaviour declares @callback functions that implementers MUST define.
        In your next transaction, ensure ALL implementers define the callbacks declared by their behaviour.
        Use get_impact_map to find all affected modules, then bulk_replace to fix consistently.
        """

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :architectural_fracture,
            reason: "behaviour_implementer_mismatch",
            message: "Behaviour-implementer mismatch — all changes rolled back",
            files: staged_files,
            fractures: report
          })
        end

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = %{state | messages: messages}
        {:noreply, state, {:continue, :step}}
    end
  end

  # NOTE: format_fracture_report has been extracted to Giulia.Inference.Transaction

  # Auto-regression phase of commit
  defp commit_auto_regress(staged_files, _params, state) do
    project_path = state.project_path || File.cwd!()
    tool_opts = build_tool_opts(state)

    # Collect test targets for all modified modules
    all_test_targets =
      Enum.flat_map(staged_files, fn path ->
        case Store.find_module_by_file(project_path, path) do
          {:ok, %{name: module_name}} ->
            case Giulia.Knowledge.Store.get_test_targets(project_path, module_name) do
              {:ok, %{all_paths: paths}} when paths != [] -> paths
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    if all_test_targets != [] do
      Logger.info("COMMIT: Running #{length(all_test_targets)} regression test file(s)")

      if state.request_id do
        Events.broadcast(state.request_id, %{
          type: :commit_testing,
          test_count: length(all_test_targets)
        })
      end

      test_results =
        Enum.map(all_test_targets, fn test_path ->
          case Giulia.Tools.RunTests.execute(%{"file" => test_path}, tool_opts) do
            {:ok, output} -> {test_path, :ok, output}
            {:error, reason} -> {test_path, :error, inspect(reason)}
          end
        end)

      failures = Enum.filter(test_results, fn {_, status, _} -> status == :error end)

      if failures == [] do
        commit_success(state)
      else
        # Tests failed — rollback
        Logger.warning("COMMIT: Auto-regression failed, rolling back")
        state = %{state | transaction: Transaction.rollback(state.transaction, state.project_path)}

        failure_summary =
          Enum.map_join(failures, "\n", fn {path, _, output} ->
            "  - #{path}: #{String.slice(output, 0, 200)}"
          end)

        error_msg = """
        COMMIT FAILED: Auto-regression tests failed. All changes have been ROLLED BACK.
        All #{length(staged_files)} files are back to their ORIGINAL state. Your staging buffer is cleared.

        Failed tests:
        #{failure_summary}

        POST-ROLLBACK REALITY CHECK:
        Your previous changes compiled but broke tests. Review the test failures above.
        In your next transaction, ensure your changes are consistent across ALL affected modules.
        Use bulk_replace for batch operations, then commit_changes to verify again.
        """

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :commit_rollback,
            reason: "test_failure",
            files: staged_files,
            message: "Auto-regression failed — all changes rolled back"
          })
        end

        messages = state.messages ++ [%{role: "user", content: error_msg}]
        state = %{state | messages: messages}
        {:noreply, state, {:continue, :step}}
      end
    else
      # No tests to run — commit succeeds
      commit_success(state)
    end
  end

  # Commit succeeded — clear staging and continue
  defp commit_success(state) do
    tx = state.transaction
    file_count = map_size(tx.staging_buffer)

    Logger.info("COMMIT: Success! #{file_count} file(s) committed")

    if state.request_id do
      Events.broadcast(state.request_id, %{
        type: :commit_success,
        file_count: file_count,
        files: Map.keys(tx.staging_buffer),
        message: "All #{file_count} file(s) verified and written to disk"
      })
    end

    observation = Transaction.success_report(tx)

    messages = state.messages ++ [%{role: "user", content: observation}]

    state = %{
      state
      | messages: messages,
        transaction: Transaction.new(),
        consecutive_failures: 0
    }

    {:noreply, state, {:continue, :step}}
  end

  # NOTE: rollback_staged_changes has been extracted to Transaction.rollback/2

  # ============================================================================
  # Transactional Exoskeleton — Auto-Enable for Hub Modules
  # ============================================================================

  # Check if a write tool targets a hub module and auto-enable transaction mode
  defp maybe_auto_enable_transaction(tool_name, params, state)
       when tool_name in @stageable_tools do
    {new_tx, new_max} =
      Transaction.maybe_auto_enable(state.transaction, params,
        tool_name: tool_name,
        project_path: state.project_path,
        resolve_module_fn: &resolve_module_from_params/3,
        request_id: state.request_id
      )

    state = %{state | transaction: new_tx}

    if new_max do
      %{state | max_iterations: max(state.max_iterations, new_max)}
    else
      state
    end
  end

  defp maybe_auto_enable_transaction(_tool_name, _params, state), do: state

  # Handle rejected approval - inform model and continue
  defp handle_rejection(tool_name, params, response, state) do
    rejection_msg = """
    USER REJECTED: Your proposed #{tool_name} was rejected by the user.

    They declined the following change:
    #{format_params_brief(params)}

    Please propose a different approach or use 'respond' to ask the user for clarification.
    """

    assistant_msg = response.content || Jason.encode!(%{tool: tool_name, parameters: params})

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: rejection_msg}
        ]

    state = %{
      state
      | messages: messages,
        action_history: [
          {tool_name, params, {:error, :rejected}} | Enum.take(state.action_history, 4)
        ],
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

    messages =
      state.messages ++
        [
          %{role: "assistant", content: assistant_msg},
          %{role: "user", content: timeout_msg}
        ]

    state = %{
      state
      | messages: messages,
        action_history: [
          {tool_name, params, {:error, :timeout}} | Enum.take(state.action_history, 4)
        ],
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

  # run_tests is read-only (runs ExUnit, reports results) — auto-approve
  defp requires_approval?("run_tests", _params, _state), do: false

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

      "run_tests" ->
        file = params["file"] || params[:file]
        test_name = params["test_name"] || params[:test_name]

        cond do
          file && test_name -> "Run tests in #{file} matching '#{test_name}'"
          file -> "Run tests in #{file}"
          test_name -> "Run all tests matching '#{test_name}'"
          true -> "Run ALL project tests"
        end

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
    file = params["file"] || params[:file] || params["path"] || params[:path]
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
    case Store.find_module(state.project_path, module) do
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

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_function_from_body(source, {:__block__, _meta, statements}, func_atom, arity) do
    ranges =
      Enum.flat_map(statements, fn stmt ->
        case match_func_def(stmt, func_atom, arity) do
          {:ok, range} -> [range]
          _ -> []
        end
      end)

    case ranges do
      [] ->
        nil

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

      _ ->
        nil
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

  defp resolve_tool_path(nil, _state), do: nil

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

  # ============================================================================
  # Hub Alarm — Topological Risk Assessment
  # ============================================================================

  # Assess the risk of modifying a module by checking its centrality in the
  # Knowledge Graph. Returns a warning string for hubs (>3 dependents), nil otherwise.
  defp assess_hub_risk(tool_name, params, project_path)
       when tool_name in ["edit_file", "patch_function", "write_function", "write_file"] do
    module_name = resolve_module_from_params(tool_name, params, project_path)

    if module_name do
      case Giulia.Knowledge.Store.centrality(project_path, module_name) do
        {:ok, %{in_degree: in_degree, dependents: dependents}} when in_degree > 3 ->
          top_dependents = Enum.take(dependents, 3) |> Enum.join(", ")

          """
          ⚠️  CRITICAL HUB WARNING ⚠️
          You are modifying #{module_name}. This module is a Hub with #{in_degree} dependents.
          A mistake here will break: #{top_dependents}#{if in_degree > 3, do: " (+#{in_degree - 3} more)", else: ""}
          Suggested regression: run tests for #{top_dependents}
          """

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp assess_hub_risk(_tool_name, _params, _project_path), do: nil

  # Resolve the module name from tool params (different tools use different param keys)
  defp resolve_module_from_params("edit_file", params, project_path) do
    file = params["file"] || params[:file]
    module_from_file_path(file, project_path)
  end

  defp resolve_module_from_params("write_file", params, project_path) do
    path = params["path"] || params[:path]
    module_from_file_path(path, project_path)
  end

  defp resolve_module_from_params(tool_name, params, _project_path)
       when tool_name in ["patch_function", "write_function"] do
    params["module"] || params[:module]
  end

  defp resolve_module_from_params(_, _, _project_path), do: nil

  # Best-effort: convert a file path to a module name via the context store
  defp module_from_file_path(nil, _project_path), do: nil

  defp module_from_file_path(path, project_path) do
    case Store.find_module_by_file(project_path, path) do
      {:ok, %{name: name}} -> name
      _ -> nil
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
    # Unclosed action tag
    |> String.replace(~r/<action>.*$/s, "")
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
    project_summary = Store.project_summary(state.project_path)
    cwd = get_working_directory(state)

    opts = [
      constitution: constitution,
      minimal: minimal,
      project_summary: project_summary,
      cwd: cwd,
      transaction_mode: state.transaction.mode,
      staged_files: Map.keys(state.transaction.staging_buffer)
    ]

    # Layer 1+2: Automatic Surgical Briefing
    briefing_opt =
      case Giulia.Intelligence.SurgicalBriefing.build(prompt, state.project_path) do
        {:ok, briefing} -> [surgical_briefing: briefing]
        :skip -> []
      end

    Builder.build_messages(prompt, opts ++ briefing_opt)
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
    recent_actions =
      state.action_history
      |> Enum.take(3)
      |> Enum.map(fn {tool, params, result} ->
        status =
          case result do
            {:ok, _} -> "OK"
            {:error, _} -> "FAILED"
            :ok -> "OK"
            _ -> "?"
          end

        "- #{tool}(#{format_params_brief(params)}) -> #{status}"
      end)
      |> Enum.join("\n")

    # Current state
    modules_count = length(Store.list_modules(state.project_path))

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

  # Targeted intervention for test failure loops.
  # The 3B model sees "1 failure" but doesn't know to read + edit.
  # We re-run the tests ourselves, read the test file, and give the model
  # everything it needs to call edit_file in one shot.
  defp build_test_failure_intervention(test_params, state) do
    test_file = test_params["file"] || test_params[:file]
    opts = build_tool_opts(state)

    # Re-run tests to get fresh failure data
    test_result =
      case Giulia.Tools.RunTests.execute(test_params, opts) do
        {:ok, result} -> result
        {:error, reason} -> "Test run failed: #{inspect(reason)}"
      end

    # Read the test file content
    test_content =
      if test_file do
        project_path = state.project_path || File.cwd!()
        full_path = Path.join(project_path, test_file)

        case File.read(full_path) do
          {:ok, content} -> content
          {:error, _} -> "(could not read test file)"
        end
      else
        "(no test file specified)"
      end

    """
    INTERVENTION: You keep running tests but not fixing the failure. STOP running tests.

    TEST RESULTS:
    #{test_result}

    TEST FILE (#{test_file}):
    #{test_content}

    The test has a WRONG ASSERTION. The test input says one value but the assert checks a different value.
    You MUST use edit_file to fix the wrong assertion in the test file.

    EXAMPLE — to fix a wrong assertion:
    <action>
    {"tool": "edit_file", "parameters": {"path": "#{test_file}", "old_text": "assert result == \\"wrong_value\\"", "new_text": "assert result == \\"correct_value\\""}}
    </action>

    DO NOT run tests again. Use edit_file NOW to fix the assertion, then use respond.
    """
  end

  defp build_intervention_message(state, target_file, fresh_content) do
    # Detect if the loop is on a read-only tool — if so, the model needs to use respond,
    # not more build/edit tools
    case state.last_action do
      {tool_name, _params} when tool_name in @read_only_tools ->
        build_readonly_intervention(tool_name, state)

      _ ->
        build_write_intervention(state, target_file, fresh_content)
    end
  end

  # Intervention for read-only tool loops — force respond
  defp build_readonly_intervention(tool_name, state) do
    last_result =
      case state.action_history do
        [{_tool, _params, result} | _] -> inspect(result, limit: 200)
        _ -> "(no result available)"
      end

    """
    REPETITION ERROR: You called "#{tool_name}" #{state.repeat_count + 1} times with the same parameters.
    The tool returned the same result each time. Repeating it will NOT change the outcome.

    Last result: #{last_result}

    You are PROHIBITED from calling #{tool_name} again with those parameters.
    You MUST do ONE of these instead:
    1. Use "respond" to answer the user with whatever information you have gathered
    2. Try a DIFFERENT tool (e.g., get_module_info, search_code, list_files)
    3. Try the SAME tool with DIFFERENT parameters (e.g., a shorter module name)

    Use respond NOW to give the user your analysis.
    """
  end

  # Intervention for write-tool loops — existing behavior (build/syntax focused)
  defp build_write_intervention(state, target_file, fresh_content) do
    error_summary =
      state.recent_errors
      |> Enum.take(3)
      |> Enum.map(&"- #{inspect(&1)}")
      |> Enum.join("\n")

    action_summary =
      state.action_history
      |> Enum.take(3)
      |> Enum.map(fn {tool, params, _} -> "- #{tool}: #{format_params_brief(params)}" end)
      |> Enum.join("\n")

    # Build fresh content section if available
    fresh_section =
      if target_file && fresh_content do
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

  defp handle_native_command(prompt, state) do
    prompt_lower = String.downcase(prompt)
    project_path = state.project_path

    cond do
      String.contains?(prompt_lower, "module") ->
        modules = Store.list_modules(project_path)
        list = Enum.map_join(modules, "\n", &"- #{&1.name} (#{&1.file})")
        {:ok, "Indexed modules:\n#{list}"}

      String.contains?(prompt_lower, "function") ->
        functions = Store.list_functions(project_path)

        list =
          functions
          |> Enum.take(20)
          |> Enum.map_join("\n", &"- #{&1.module}.#{&1.name}/#{&1.arity}")

        {:ok, "Functions (first 20):\n#{list}"}

      String.contains?(prompt_lower, "status") ->
        stats = Store.stats(project_path)
        {:ok, "Index: #{stats.ast_files} files, #{stats.total_entries} entries"}

      String.contains?(prompt_lower, "summary") ->
        {:ok, Store.project_summary(project_path)}

      true ->
        {:ok, "Native command not recognized. Ask about modules, functions, status, or summary."}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_model_response(%{content: nil}), do: {:error, :empty_response}

  defp parse_model_response(%{tool_calls: [tc | _]}) do
    {:tool_call, tc.name, tc.arguments}
  end

  defp parse_model_response(%{content: content}) when is_binary(content) do
    # Log raw model output for debugging
    Logger.info("Raw model response: #{String.slice(content, 0, 300)}")

    # Try hybrid parser first when <payload> or <action> tags are present
    if Parser.hybrid_format?(content) or String.contains?(content, "<action>") do
      # Check for multiple <action> blocks first (batched tool calls)
      action_count = length(Regex.scan(~r/<action>/, content))

      if action_count > 1 do
        case Parser.parse_all_actions(content) do
          {:ok, [first | rest]} ->
            Logger.info(
              "Parsed #{action_count} batched actions via Parser (executing sequentially)"
            )

            {:multi_tool_call, first["tool"], first["parameters"], rest}

          {:error, reason} ->
            Logger.warning("Multi-action parse failed (#{inspect(reason)}), trying single")
            parse_single_action(content)
        end
      else
        parse_single_action(content)
      end
    else
      parse_model_response_json(content)
    end
  end

  defp parse_model_response(_), do: {:error, :unknown_response_format}

  defp parse_single_action(content) do
    case Parser.parse_response(content) do
      {:ok, %{"tool" => tool, "parameters" => params}} ->
        Logger.info("Parsed via hybrid Parser: tool=#{tool}")
        {:tool_call, tool, params}

      {:error, reason} ->
        Logger.warning("Hybrid parse failed (#{inspect(reason)}), falling back to JSON path")
        parse_model_response_json(content)
    end
  end

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

    %{
      state
      | task: nil,
        status: :idle,
        messages: [],
        reply_to: nil,
        iteration: 0,
        consecutive_failures: 0,
        last_action: nil,
        repeat_count: 0,
        action_history: [],
        recent_errors: [],
        final_response: nil,
        pending_verification: false,
        test_status: :untested,
        transaction: Transaction.new(),
        pending_tool_calls: [],
        last_impact_map: nil,
        modified_files: MapSet.new()
    }
  end

  defp build_tool_opts(state) do
    opts = []

    # Add project path for tools like run_mix
    opts =
      if state.project_path do
        Keyword.put(opts, :project_path, state.project_path)
      else
        opts
      end

    # Add project pid for dirty state tracking
    opts =
      if state.project_pid do
        Keyword.put(opts, :project_pid, state.project_pid)
      else
        opts
      end

    # Add sandbox for file operations
    opts =
      if state.project_path do
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
    project_path = Keyword.get(tool_opts, :project_path)
    file_path = get_file_path_from_params(tool_name, params, project_path)

    if file_path do
      case Registry.execute("read_file", %{"path" => file_path}, tool_opts) do
        {:ok, file_content} ->
          # Truncate for context window
          truncated =
            if String.length(file_content) > 2000 do
              String.slice(file_content, 0, 2000) <>
                "\n\n... [truncated, #{String.length(file_content)} bytes total]"
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

  # Find the best successful tool observation from action_history.
  # Used by Heuristic Completion to deliver data when the model loops on read-only tools.
  # Picks the LONGEST successful result — substantive data (impact maps, traces) is always
  # longer than error messages ("not found in graph").
  defp find_last_successful_observation(state) do
    state.action_history
    |> Enum.flat_map(fn
      {_tool, _params, {:ok, data}} when is_binary(data) and data != "" -> [data]
      _ -> []
    end)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  # Extract the file path from tool params
  defp get_file_path_from_params("edit_file", params, _project_path) do
    params["file"] || params[:file]
  end

  defp get_file_path_from_params("write_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params("patch_function", params, project_path) do
    lookup_module_file(params["module"] || params[:module], project_path)
  end

  defp get_file_path_from_params(_tool, _params, _project_path), do: nil

  # ============================================================================
  # Goal Tracker — Premature Completion Detection
  # ============================================================================

  # Should the Goal Tracker block the respond call?
  # Returns true if:
  # 1. An impact_map was captured with >= 3 dependents
  # 2. The number of modified files is less than 50% of dependents
  defp goal_tracker_blocks?(state) do
    im = state.last_impact_map
    touched = MapSet.size(state.modified_files)

    # Only block if there were significant dependents (>= 3)
    # and the model touched less than half of them
    im.count >= 3 and touched < div(im.count, 2)
  end

  # Extract downstream dependent module names from the impact map output text
  defp extract_downstream_dependents(result_str) do
    # The impact map format has a "DOWNSTREAM" section with lines like:
    #   - Giulia.Tools.EditFile (direct)
    #   - Giulia.Agent.Orchestrator (depth 2)
    case String.split(result_str, "DOWNSTREAM (what depends on me):") do
      [_, downstream_section] ->
        downstream_section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("- ")
          |> String.split(" (")
          |> List.first()
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == "" or &1 == "(none — nothing depends on this)"))
        # Stop at the FUNCTIONS section or end
        |> Enum.take_while(&(not String.starts_with?(&1, "FUNCTIONS")))

      _ ->
        []
    end
  end

  # Convert a module name to a path fragment for fuzzy matching
  # "Giulia.Tools.EditFile" -> "edit_file"
  defp module_to_path(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
