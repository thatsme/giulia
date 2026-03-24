defmodule Giulia.Inference.ContextBuilder.Messages do
  @moduledoc """
  Message construction for the inference pipeline.

  Initial messages, context injection, and context reminders.
  """

  alias Giulia.Context.Store
  alias Giulia.Inference.ContextBuilder.Helpers
  alias Giulia.Inference.State
  alias Giulia.Prompt.Builder

  @doc "Build the initial message list for a new inference."
  @spec build_initial_messages(String.t(), map(), module()) :: [map()]
  def build_initial_messages(prompt, state, provider_module) do
    constitution = Helpers.get_constitution(state.project_pid)
    minimal = provider_module == Giulia.Provider.LMStudio

    project_summary = Store.Formatter.project_summary(state.project_path)
    cwd = Helpers.get_working_directory(state)

    opts = [
      constitution: constitution,
      minimal: minimal,
      project_summary: project_summary,
      cwd: cwd,
      transaction_mode: state.transaction.mode,
      staged_files: Map.keys(state.transaction.staging_buffer)
    ]

    briefing_opt =
      case Giulia.Intelligence.SurgicalBriefing.build(prompt, state.project_path) do
        {:ok, briefing} -> [surgical_briefing: briefing]
        :skip -> []
      end

    Builder.build_messages(prompt, opts ++ briefing_opt)
  end

  @doc "Inject distilled context into messages (after first iteration)."
  @spec inject_distilled_context([map()], map()) :: [map()]
  def inject_distilled_context(messages, state) do
    if state.action_history == [] do
      messages
    else
      context = build_context_reminder(state)

      case List.last(messages) do
        %{role: "user", content: content} ->
          List.replace_at(messages, -1, %{role: "user", content: content <> "\n\n" <> context})

        _ ->
          messages ++ [%{role: "user", content: context}]
      end
    end
  end

  @doc "Build the context reminder string."
  @spec build_context_reminder(map()) :: String.t()
  def build_context_reminder(state) do
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

        "- #{tool}(#{Helpers.format_params_brief(params)}) -> #{status}"
      end)
      |> Enum.join("\n")

    modules_count = length(Store.Query.list_modules(state.project_path))

    """
    [CONTEXT REMINDER]
    Iteration: #{State.iteration(state)}/#{State.max_iterations(state)}
    Indexed modules: #{modules_count}
    Recent actions:
    #{recent_actions}
    """
  end

  @doc "Count recent consecutive think calls."
  @spec count_recent_thinks([tuple()]) :: non_neg_integer()
  def count_recent_thinks(action_history) do
    action_history
    |> Enum.take_while(fn {tool, _, _} -> tool == "think" end)
    |> length()
  end
end
