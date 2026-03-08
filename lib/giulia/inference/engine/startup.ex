defmodule Giulia.Inference.Engine.Startup do
  @moduledoc """
  Handles the `{:start, prompt, opts}` dispatch — provider resolution,
  baseline check, initial message construction, and telemetry emission.

  Extracted from Engine in build 112.
  """

  require Logger

  alias Giulia.Provider.Router
  alias Giulia.Prompt.Builder
  alias Giulia.Context.Store
  alias Giulia.Inference.{ContextBuilder, State, Verification}
  alias Giulia.Inference.Engine.Helpers

  @doc """
  Start the inference loop: check baseline, resolve provider, build messages.
  """
  @spec run(String.t(), keyword(), State.t()) :: Giulia.Inference.Engine.directive()
  def run(prompt, _opts, state) do
    Logger.info("Orchestrator starting: #{String.slice(prompt, 0, 50)}...")

    Builder.clear_model_tier_cache()

    baseline_status = check_baseline(state)
    state = State.set_baseline(state, baseline_status)

    if baseline_status == :dirty do
      Helpers.maybe_broadcast(state, %{
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
      Helpers.done_with_telemetry(result, state)
    else
      case resolve_provider(classification) do
        {:ok, final_provider, final_module} ->
          model_tier = Builder.detect_model_tier()
          detected_name = Application.get_env(:giulia, :detected_model_name, "unknown")

          Helpers.maybe_broadcast(state, %{
            type: :model_detected,
            model: detected_name,
            tier: model_tier,
            message: "Model: #{detected_name} (#{model_tier} tier)"
          })

          messages = ContextBuilder.build_initial_messages(prompt, state, final_module)

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

          state = state
            |> State.set_status(:thinking)
            |> State.set_messages(messages)
            |> State.set_provider(final_provider, final_module)
            |> State.reset_failures()
            |> put_in([Access.key(:counters), :iteration], 0)
            |> Map.put(:action_history, [])

          :telemetry.execute(
            [:giulia, :inference, :start],
            %{system_time: System.system_time(:millisecond)},
            %{prompt: String.slice(prompt, 0, 200), provider: final_provider, request_id: state.request_id}
          )

          {:next, :step, state}

        :no_provider ->
          Helpers.done_with_telemetry({:error, :no_provider_available}, state)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_baseline(state) do
    Verification.check_baseline(state.project_path, ContextBuilder.build_tool_opts(state))
  end

  defp resolve_provider(classification) do
    if Router.provider_available?(classification.provider) do
      {:ok, classification.provider, Router.get_provider_module(classification.provider)}
    else
      fallback = Router.fallback(classification.provider)

      if fallback && Router.provider_available?(fallback) do
        Logger.info("Using fallback provider: #{fallback}")
        {:ok, fallback, Router.get_provider_module(fallback)}
      else
        :no_provider
      end
    end
  end

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
end
