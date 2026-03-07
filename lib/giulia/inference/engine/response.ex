defmodule Giulia.Inference.Engine.Response do
  @moduledoc """
  Model response parsing, gate enforcement (staging-lock, test-lock,
  goal-tracker), and response sub-handlers.

  Extracted from Engine in build 112.
  """

  require Logger

  alias Giulia.StructuredOutput
  alias Giulia.Inference.{ContextBuilder, Events, ResponseParser, State, ToolDispatch}
  alias Giulia.Inference.Engine.Helpers

  @doc """
  Parse an LLM response and dispatch to the appropriate handler.
  Emits `[:giulia, :llm, :parsed]` telemetry.
  """
  @spec handle_model_response(map(), State.t()) :: Giulia.Inference.Engine.directive()
  def handle_model_response(response, state) do
    parsed = ResponseParser.parse(response)

    # Telemetry: emit parsed event with result type and think block extraction
    {result_type, tool_name_for_telemetry} = classify_parsed(parsed)
    think_block = extract_think_block(response)

    :telemetry.execute(
      [:giulia, :llm, :parsed],
      %{system_time: System.system_time(:millisecond)},
      %{
        result_type: result_type,
        tool: tool_name_for_telemetry,
        think: think_block,
        request_id: state.request_id
      }
    )

    case parsed do
      {:tool_call, "respond", %{"message" => message}} ->
        handle_respond(message, state)

      {:tool_call, "think", %{"thought" => thought}} ->
        handle_think(thought, response, state)

      {:multi_tool_call, tool_name, params, remaining} ->
        Logger.info("Multi-action: executing #{tool_name}, queuing #{length(remaining)} more")
        state = State.set_pending_tool_calls(state, remaining)
        ToolDispatch.execute(tool_name, params, response, state)

      {:tool_call, tool_name, params} ->
        ToolDispatch.execute(tool_name, params, response, state)

      {:text, text} ->
        handle_plain_text_response(text, response, state)

      {:error, {:json_escape_error, position, malformed_json}} ->
        handle_json_escape_error(position, malformed_json, state)

      {:error, reason} ->
        Logger.warning("Failed to parse response: #{inspect(reason)}")
        state = State.increment_failures(state)
        {:next, :step, state}
    end
  end

  # ============================================================================
  # Response Sub-handlers
  # ============================================================================

  defp handle_respond(message, state) do
    cond do
      # STAGING-LOCK GATE
      state.transaction.mode and map_size(state.transaction.staging_buffer) > 0 ->
        tx = state.transaction
        lock_count = tx.lock_count + 1

        Logger.warning(
          "STAGING-LOCK: Model tried to respond with #{map_size(tx.staging_buffer)} uncommitted staged file(s) (attempt #{lock_count})"
        )

        if lock_count >= 3 do
          Logger.warning(
            "STAGING-LOCK: #{lock_count} consecutive blocks — clearing staging buffer to break deadlock"
          )

          Logger.info("=== TASK COMPLETE (staging-lock release) ===")
          state = State.set_transaction(state, Giulia.Inference.Transaction.new())
          Helpers.done_with_telemetry({:ok, message}, state)
        else
          staged_list =
            tx.staging_buffer |> Map.keys() |> Enum.map_join("\n", &"  - #{&1}")

          lock_msg = """
          BLOCKED: You have uncommitted staged changes in #{map_size(tx.staging_buffer)} file(s):
          #{staged_list}

          You MUST call commit_changes before respond. Or fix your changes and try again.
          """

          messages = state.messages ++ [%{role: "user", content: lock_msg}]
          state = state |> State.set_messages(messages) |> State.set_transaction(%{tx | lock_count: lock_count})
          {:next, :step, state}
        end

      # TEST-LOCK GATE
      State.test_status(state) == :red ->
        Logger.warning("TEST-LOCK: Model tried to respond but tests are still RED")

        lock_msg = """
        BLOCKED: You cannot close this task. Tests are still FAILING.
        You MUST call run_tests and get 0 failures before you can respond.
        Do NOT claim success based on a green build alone.
        DEFINITION OF DONE: build green AND tests green AND verified.
        """

        messages = state.messages ++ [%{role: "user", content: lock_msg}]
        state = State.set_messages(state, messages)
        {:next, :step, state}

      # GOAL TRACKER GATE
      not is_nil(state.goal.last_impact_map) and goal_tracker_blocks?(state) ->
        im = state.goal.last_impact_map
        touched = MapSet.size(state.goal.modified_files)
        state = State.increment_goal_blocks(state)
        block_count = State.goal_tracker_blocks(state)

        Logger.warning(
          "GOAL TRACKER: Model tried to respond after touching #{touched}/#{im.count} dependents of #{im.module} (block #{block_count})"
        )

        if state.request_id do
          Events.broadcast(state.request_id, %{
            type: :goal_tracker_block,
            module: im.module,
            dependents: im.count,
            modified: touched
          })
        end

        if block_count >= 4 do
          Logger.warning(
            "GOAL TRACKER: #{block_count} consecutive blocks — releasing to break deadlock"
          )

          Logger.info("=== TASK COMPLETE (goal-tracker release) ===")
          state = State.reset_goal_blocks(state)
          Helpers.done_with_telemetry({:ok, message}, state)
        else
          untouched =
            im.dependents
            |> Enum.reject(fn dep ->
              Enum.any?(
                MapSet.to_list(state.goal.modified_files),
                &String.contains?(&1, ToolDispatch.module_to_path(dep))
              )
            end)
            |> Enum.take(10)

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
          state = State.set_messages(state, messages)
          {:next, :step, state}
        end

      true ->
        Logger.info("=== TASK COMPLETE ===")
        Logger.info("Iterations: #{State.iteration(state)}")
        Logger.info("Response: #{String.slice(message, 0, 300)}")
        Helpers.done_with_telemetry({:ok, message}, state)
    end
  end

  defp handle_think(thought, response, state) do
    Logger.info("=== MODEL THINKING ===")
    Logger.info("Thought: #{String.slice(thought, 0, 300)}")

    think_count = ContextBuilder.count_recent_thinks(state.action_history)

    if think_count >= 2 do
      Logger.warning("Too many consecutive thinks (#{think_count}), forcing respond")

      nudge_msg =
        "You have been thinking too long. Use respond NOW to answer the user's question based on what you know."

      messages = state.messages ++ [%{role: "user", content: nudge_msg}]
      state = state |> State.set_messages(messages) |> State.reset_failures()
      {:next, :step, state}
    else
      assistant_msg =
        response.content || Jason.encode!(%{tool: "think", parameters: %{thought: thought}})

      messages = state.messages ++ [%{role: "assistant", content: assistant_msg}]

      state = state
        |> State.set_messages(messages)
        |> State.reset_failures()
        |> State.record_action({"think", %{}, :ok})

      {:next, :step, state}
    end
  end

  defp handle_plain_text_response(text, response, state) do
    case StructuredOutput.extract_json(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, _parsed} ->
            handle_model_response(%{response | content: json}, state)

          {:error, _} ->
            Helpers.done_with_telemetry({:ok, ResponseParser.clean_output(text)}, state)
        end

      {:error, _} ->
        Helpers.done_with_telemetry({:ok, ResponseParser.clean_output(text)}, state)
    end
  end

  defp handle_json_escape_error(position, malformed_json, state) do
    Logger.info("=== JSON ESCAPE ERROR - REQUESTING RETRY ===")
    Logger.info("Error at position: #{position}")

    error_context = ResponseParser.extract_error_context(malformed_json, position)

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

    state = state |> State.set_messages(messages) |> State.increment_failures()

    if State.max_failures?(state) do
      Logger.warning("Max JSON retries exceeded - giving up")
      {:next, :intervene, state}
    else
      Logger.info("Retrying after JSON escape error (attempt #{State.consecutive_failures(state)})")
      {:next, :step, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp classify_parsed(parsed) do
    case parsed do
      {:tool_call, name, _} -> {:tool_call, name}
      {:multi_tool_call, name, _, _} -> {:multi_tool_call, name}
      {:text, _} -> {:text, nil}
      {:error, _} -> {:error, nil}
    end
  end

  defp extract_think_block(response) do
    content = response.content || ""
    case Regex.run(~r/<think>([\s\S]*?)<\/think>/, content) do
      [_, think] -> String.trim(think)
      _ -> nil
    end
  end

  defp goal_tracker_blocks?(state) do
    im = state.goal.last_impact_map
    touched = MapSet.size(state.goal.modified_files)
    im.count >= 3 and touched < div(im.count, 2)
  end
end
