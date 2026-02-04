defmodule Giulia.Agent.Orchestrator do
  @moduledoc """
  The "Think-Action-Verify" Loop with Integrated Feedback.

  A GenServer that maintains state across the agent loop:
  - Step counter for iteration limits
  - Retry counter for hallucination detection
  - Recent errors for intervention context
  - Reflection: Verify model suggestions via AST before execution

  The Skeptical Supervisor: We don't trust the model blindly.
  """
  use GenServer

  require Logger

  alias Giulia.Context.{Store, Builder}
  alias Giulia.Tools.Registry
  alias Giulia.Agent.Router
  alias Giulia.StructuredOutput

  @max_iterations 20
  @max_consecutive_failures 3

  defstruct [
    :task,
    :project_path,
    :messages,
    :status,
    # Counters
    iteration: 0,
    consecutive_failures: 0,
    same_action_count: 0,
    # History
    last_action: nil,
    recent_errors: [],
    action_history: [],
    # Config
    max_iterations: @max_iterations,
    use_routing: true
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a new agent task under the supervisor.
  """
  def run(task, opts \\ []) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Giulia.Agent.Supervisor,
        {__MODULE__, Keyword.merge([task: task], opts)}
      )

    GenServer.call(pid, :run, :infinity)
  end

  @doc """
  Get the current state of the orchestrator.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      task: Keyword.fetch!(opts, :task),
      project_path: Keyword.get(opts, :project_path) || get_project_path(),
      messages: [],
      status: :initialized,
      max_iterations: Keyword.get(opts, :max_iterations, @max_iterations),
      use_routing: Keyword.get(opts, :use_routing, true)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    result = execute_loop(state)
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # ============================================================================
  # The Loop
  # ============================================================================

  defp execute_loop(%{iteration: i, max_iterations: max}) when i >= max do
    Logger.warning("Max iterations reached (#{max})")
    {:error, :max_iterations}
  end

  defp execute_loop(%{consecutive_failures: f}) when f >= @max_consecutive_failures do
    Logger.warning("Loop of death detected - #{f} consecutive failures")
    {:error, :hallucination_loop}
  end

  defp execute_loop(state) do
    state = %{state | iteration: state.iteration + 1, status: :thinking}
    Logger.info("Iteration #{state.iteration}: Thinking...")

    # Step A: Build context and get model response
    messages = build_messages(state)
    tools = Builder.build_tools_list()

    # Route to appropriate provider
    {provider, classification} =
      if state.use_routing do
        c = Router.classify(state.task) |> Router.ensure_provider_available()
        {c.provider, c}
      else
        {Giulia.Provider.current(), nil}
      end

    if classification do
      Logger.debug("Routed to #{inspect(provider)} - #{classification.reason}")
    end

    case provider.chat(messages, tools, []) do
      {:ok, %{stop_reason: :end_turn, content: content}} ->
        Logger.info("Task complete")
        {:ok, content}

      {:ok, %{stop_reason: :tool_use, tool_calls: tool_calls}} ->
        # Step B: Validate and potentially intercept
        handle_tool_calls(state, tool_calls)

      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        # Model responded with text instead of tool - might be done
        Logger.info("Model responded with text (no tool call)")
        {:ok, content}

      {:error, reason} ->
        Logger.error("Provider error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Tool Handling (The Skeptical Supervisor)
  # ============================================================================

  defp handle_tool_calls(state, tool_calls) do
    Logger.info("Processing #{length(tool_calls)} tool call(s)")

    # Process each tool call with validation
    results =
      Enum.map(tool_calls, fn call ->
        handle_single_tool_call(state, call)
      end)

    # Check for failures
    {successes, failures} = Enum.split_with(results, &match?({:ok, _, _}, &1))

    cond do
      # All succeeded
      failures == [] ->
        state = record_success(state, tool_calls, successes)
        continue_loop(state, successes)

      # Some failed - send correction
      length(failures) > 0 and state.consecutive_failures < @max_consecutive_failures - 1 ->
        state = record_failure(state, tool_calls, failures)
        send_correction(state, failures)

      # Too many failures - intervention
      true ->
        force_intervention(state)
    end
  end

  defp handle_single_tool_call(state, %{name: name, arguments: _args} = call) do
    Logger.debug("Tool call: #{name}")

    # Step B.1: Validate via schema
    case StructuredOutput.validate_tool_call(call) do
      {:ok, validated_struct} ->
        # Step B.2: Reflection - verify assumptions via AST if applicable
        case reflect_on_action(state, name, validated_struct) do
          :ok ->
            # Step B.3: Execute
            execute_tool(name, validated_struct)

          {:intercept, reason} ->
            # Reflection caught a problem - don't execute
            {:error, name, {:reflection_intercept, reason}}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        {:error, name, {:validation, errors}}

      {:error, {:unknown_tool, _}} = error ->
        {:error, name, error}
    end
  end

  defp execute_tool(name, validated_struct) do
    case Registry.execute(name, validated_struct) do
      {:ok, result} -> {:ok, name, result}
      {:error, reason} -> {:error, name, reason}
    end
  end

  # ============================================================================
  # Reflection (Verify Before Execute)
  # ============================================================================

  defp reflect_on_action(_state, "write_file", %Giulia.Tools.WriteFile{path: path}) do
    # Check if the file exists in our AST index
    case Store.get_ast(path) do
      {:ok, _ast_data} ->
        # File exists - that's fine, we're overwriting
        :ok

      :error ->
        # New file - that's fine
        :ok
    end
  end

  defp reflect_on_action(state, "read_file", %Giulia.Tools.ReadFile{path: path}) do
    # Verify the file actually exists before we ask the model to process it
    normalized = Path.expand(path, state.project_path)

    if File.exists?(normalized) do
      :ok
    else
      # Check if we have a similar file in the index
      similar = find_similar_paths(path)

      if similar != [] do
        {:intercept, "File '#{path}' not found. Did you mean: #{Enum.join(similar, ", ")}?"}
      else
        # Let the tool fail naturally with a clear error
        :ok
      end
    end
  end

  defp reflect_on_action(_state, _tool, _args), do: :ok

  defp find_similar_paths(target_path) do
    target_basename = Path.basename(target_path)

    Store.all_asts()
    |> Map.keys()
    |> Enum.filter(fn path ->
      basename = Path.basename(path)
      String.jaro_distance(basename, target_basename) > 0.7
    end)
    |> Enum.take(3)
  end

  # ============================================================================
  # State Management
  # ============================================================================

  defp record_success(state, tool_calls, _results) do
    action_key = tool_calls |> Enum.map(& &1.name) |> Enum.sort()

    %{state |
      consecutive_failures: 0,
      same_action_count: 0,
      last_action: action_key,
      action_history: [action_key | Enum.take(state.action_history, 9)],
      recent_errors: []
    }
  end

  defp record_failure(state, tool_calls, failures) do
    action_key = tool_calls |> Enum.map(& &1.name) |> Enum.sort()

    same_action_count =
      if action_key == state.last_action do
        state.same_action_count + 1
      else
        1
      end

    error_messages = Enum.map(failures, fn {:error, name, reason} ->
      "#{name}: #{inspect(reason)}"
    end)

    %{state |
      consecutive_failures: state.consecutive_failures + 1,
      same_action_count: same_action_count,
      last_action: action_key,
      recent_errors: (error_messages ++ state.recent_errors) |> Enum.take(5)
    }
  end

  # ============================================================================
  # Loop Control
  # ============================================================================

  defp continue_loop(state, results) do
    # Add tool results to messages
    observations =
      Enum.map(results, fn {:ok, name, result} ->
        Builder.build_observation(name, {:ok, result})
      end)

    new_messages = Enum.map(observations, fn obs ->
      %{role: "user", content: obs}
    end)

    new_state = %{state | messages: state.messages ++ new_messages}
    execute_loop(new_state)
  end

  defp send_correction(state, failures) do
    # Build correction messages
    corrections =
      Enum.map(failures, fn {:error, name, reason} ->
        case reason do
          {:validation, errors} ->
            valid_tools = Registry.list_tool_names()
            Builder.build_correction_message(name, errors, valid_tools)

          {:unknown_tool, _, available} ->
            "Unknown tool '#{name}'. Available tools: #{Enum.join(available, ", ")}"

          {:reflection_intercept, message} ->
            "INTERCEPT: #{message}"

          other ->
            "Tool '#{name}' failed: #{inspect(other)}"
        end
      end)

    correction_msg = %{role: "user", content: Enum.join(corrections, "\n\n")}
    new_state = %{state | messages: state.messages ++ [correction_msg]}

    execute_loop(new_state)
  end

  defp force_intervention(state) do
    Logger.warning("Forcing intervention after #{state.consecutive_failures} failures")

    # Clear recent messages and inject intervention
    intervention = Builder.build_intervention_message(
      state.consecutive_failures,
      state.recent_errors
    )

    # Reset state but keep task
    new_state = %{state |
      messages: [%{role: "user", content: intervention}],
      consecutive_failures: 0,
      same_action_count: 0,
      recent_errors: [],
      iteration: state.iteration  # Keep iteration count
    }

    execute_loop(new_state)
  end

  # ============================================================================
  # Message Building
  # ============================================================================

  defp build_messages(state) do
    system_prompt = Builder.build_system_prompt(project_path: state.project_path)

    base_messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "Task: #{state.task}"}
    ]

    base_messages ++ state.messages
  end

  defp get_project_path do
    case Store.get(:project_path) do
      {:ok, path} -> path
      :error -> File.cwd!()
    end
  end
end
