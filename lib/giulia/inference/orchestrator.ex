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
  alias Giulia.Context.Store
  alias Giulia.Core.{ProjectContext, PathMapper}
  alias Giulia.Inference.Trace

  # Tools that modify code and need verification
  @write_tools ["write_file", "edit_file", "write_function"]

  defstruct [
    # Task info
    task: nil,
    project_path: nil,
    project_pid: nil,
    reply_to: nil,
    request_id: nil,  # For event broadcasting

    # State machine
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
    pending_verification: false
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
  # The OODA Loop via handle_continue
  # ============================================================================

  @impl true
  def handle_continue({:start, prompt, opts}, state) do
    Logger.info("Orchestrator starting: #{String.slice(prompt, 0, 50)}...")

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
          # Build initial messages with distilled context
          messages = build_initial_messages(prompt, state, final_module)

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

  # Intervention step
  @impl true
  def handle_continue(:intervene, state) do
    Logger.warning("Intervention triggered")

    intervention_msg = build_intervention_message(state)

    # Reset with fresh context
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
      status: :thinking
    }

    {:noreply, state, {:continue, :step}}
  end

  # Verification step (after write/edit)
  @impl true
  def handle_continue({:verify, tool_name, result}, state) do
    Logger.info("Auto-verifying after #{tool_name}")

    # Run compile to check for errors
    tool_opts = build_tool_opts(state)
    case Registry.execute("run_mix", %{"command" => "compile"}, tool_opts) do
      {:ok, output} ->
        if String.contains?(output, "error") or String.contains?(output, "Exit code:") do
          # Compilation failed - feed error back to model
          Logger.warning("Verification failed - compilation error")

          error_msg = """
          VERIFICATION FAILED: Your #{tool_name} broke the build.

          Compiler output:
          #{String.slice(output, 0, 1500)}

          Fix the error before proceeding.
          """

          messages = state.messages ++ [%{role: "user", content: error_msg}]
          state = %{state | messages: messages, pending_verification: false}
          {:noreply, state, {:continue, :step}}
        else
          # Compilation succeeded - continue normally
          Logger.info("Verification passed")
          observation = Builder.format_observation(tool_name, result)
          messages = state.messages ++ [%{role: "user", content: observation}]
          state = %{state | messages: messages, pending_verification: false}
          {:noreply, state, {:continue, :step}}
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

      {:error, reason} ->
        Logger.warning("Failed to parse response: #{inspect(reason)}")
        state = %{state | consecutive_failures: state.consecutive_failures + 1}
        {:noreply, state, {:continue, :step}}
    end
  end

  defp execute_tool(tool_name, params, response, state) do
    alias Giulia.Inference.Events
    current_action = {tool_name, params}

    # Loop detection
    if current_action == state.last_action do
      Logger.warning("Same action repeated - intervening")
      {:noreply, state, {:continue, :intervene}}
    else
      # BROADCAST: Tool call starting (only if we have a request_id)
      if state.request_id do
        Logger.info("OODA BROADCAST: tool_call #{tool_name} to #{state.request_id}")
        Events.broadcast(state.request_id, %{
          type: :tool_call,
          iteration: state.iteration,
          tool: tool_name,
          params: params
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
  end

  defp handle_plain_text_response(text, response, state) do
    case StructuredOutput.extract_json(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, parsed} ->
            handle_model_response(%{response | content: json}, state)
          {:error, _} ->
            # Accept as final response
            send_reply(state, {:ok, text})
            {:noreply, reset_state(state)}
        end
      {:error, _} ->
        # Plain text - accept as response
        send_reply(state, {:ok, text})
        {:noreply, reset_state(state)}
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

  defp build_intervention_message(state) do
    error_summary = state.recent_errors
    |> Enum.take(3)
    |> Enum.map(&"- #{inspect(&1)}")
    |> Enum.join("\n")

    action_summary = state.action_history
    |> Enum.take(3)
    |> Enum.map(fn {tool, params, _} -> "- #{tool}: #{format_params_brief(params)}" end)
    |> Enum.join("\n")

    """
    INTERVENTION: You appear to be stuck in a loop.

    Recent errors:
    #{if error_summary == "", do: "(none)", else: error_summary}

    Recent actions:
    #{if action_summary == "", do: "(none)", else: action_summary}

    INSTRUCTIONS:
    1. Stop repeating the same action
    2. Use list_files or search_code to verify paths exist
    3. Use get_module_info to check what's indexed
    4. If you cannot complete the task, use respond to explain why

    What would you like to try differently?
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
    # Debug: Log raw model output
    Logger.debug("Raw model response: #{String.slice(content, 0, 500)}")

    case StructuredOutput.extract_json(content) do
      {:ok, json} ->
        Logger.debug("Extracted JSON: #{json}")
        case Jason.decode(json) do
          {:ok, %{"tool" => tool, "parameters" => params}} ->
            {:tool_call, tool, params}
          {:ok, %{"tool" => tool}} ->
            # Model didn't include parameters - log warning
            Logger.warning("Tool call missing parameters: #{tool}")
            {:tool_call, tool, %{}}
          {:ok, decoded} ->
            Logger.warning("Invalid tool format: #{inspect(decoded)}")
            {:error, :invalid_tool_format}
          {:error, decode_error} ->
            Logger.warning("JSON decode error: #{inspect(decode_error)}")
            {:text, content}
        end
      {:error, reason} ->
        Logger.debug("No JSON found: #{inspect(reason)}")
        {:text, content}
    end
  end

  defp parse_model_response(%{tool_calls: [tc | _]}) do
    {:tool_call, tc.name, tc.arguments}
  end

  defp parse_model_response(_), do: {:error, :unknown_response_format}

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

    # Add sandbox for file operations
    opts = if state.project_path do
      sandbox = Giulia.Core.PathSandbox.new(state.project_path)
      Keyword.put(opts, :sandbox, sandbox)
    else
      opts
    end

    opts
  end
end
