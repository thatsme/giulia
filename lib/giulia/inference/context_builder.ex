defmodule Giulia.Inference.ContextBuilder do
  @moduledoc """
  Facade for message/prompt construction, previews, interventions, and hub risk assessment.

  Delegates to sub-modules:
  - Messages: initial messages, context injection, reminders
  - Intervention: tool loop and failure interventions
  - Preview: approval previews (write, edit, function diffs)
  - Helpers: tool opts, path resolution, param formatting, file extraction
  """

  alias Giulia.Context.Store
  alias Giulia.Core.PathSandbox
  alias Giulia.Inference.ContextBuilder.{Helpers, Intervention, Messages, Preview}

  # ============================================================================
  # Delegates — Messages
  # ============================================================================

  @spec build_initial_messages(String.t(), map(), module()) :: [map()]
  defdelegate build_initial_messages(prompt, state, provider_module), to: Messages

  @spec inject_distilled_context([map()], map()) :: [map()]
  defdelegate inject_distilled_context(messages, state), to: Messages

  @spec build_context_reminder(map()) :: String.t()
  defdelegate build_context_reminder(state), to: Messages

  @spec count_recent_thinks([tuple()]) :: non_neg_integer()
  defdelegate count_recent_thinks(action_history), to: Messages

  # ============================================================================
  # Delegates — Intervention
  # ============================================================================

  @spec build_intervention_message(map(), String.t() | nil, String.t() | nil) :: String.t()
  defdelegate build_intervention_message(state, target_file, fresh_content), to: Intervention

  @spec build_test_failure_intervention(map(), map()) :: String.t()
  defdelegate build_test_failure_intervention(test_params, state), to: Intervention

  @spec build_readonly_intervention(String.t(), map()) :: String.t()
  defdelegate build_readonly_intervention(tool_name, state), to: Intervention

  @spec build_write_intervention(map(), String.t() | nil, String.t() | nil) :: String.t()
  defdelegate build_write_intervention(state, target_file, fresh_content), to: Intervention

  # ============================================================================
  # Delegates — Preview
  # ============================================================================

  @spec generate_preview(String.t(), map(), map()) :: String.t()
  defdelegate generate_preview(tool_name, params, state), to: Preview

  # ============================================================================
  # Delegates — Helpers
  # ============================================================================

  @spec build_tool_opts(map()) :: keyword()
  defdelegate build_tool_opts(state), to: Helpers

  @spec extract_target_file(map()) :: String.t() | nil
  defdelegate extract_target_file(state), to: Helpers

  @spec read_fresh_content(String.t(), map()) :: String.t() | nil
  defdelegate read_fresh_content(file_path, state), to: Helpers

  @spec resolve_tool_path(String.t() | nil, map()) :: String.t() | nil
  defdelegate resolve_tool_path(path, state), to: Helpers

  @spec format_params_brief(map()) :: String.t()
  defdelegate format_params_brief(params), to: Helpers

  @spec sanitize_params_for_broadcast(map() | term()) :: map() | term()
  defdelegate sanitize_params_for_broadcast(params), to: Helpers

  @spec get_working_directory(map()) :: String.t()
  defdelegate get_working_directory(state), to: Helpers

  # ============================================================================
  # Test Hints & Hub Risk Assessment (kept in facade — tightly coupled cluster)
  # ============================================================================

  @write_tools ["write_file", "edit_file", "write_function", "patch_function"]

  @doc "Build test hints for BUILD GREEN observations."
  @spec build_test_hint(map()) :: String.t()
  def build_test_hint(state) do
    target_file = Helpers.extract_target_file(state)
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

  defp build_direct_test_hint(_target_file, %{project_path: nil}), do: ""

  defp build_direct_test_hint(target_file, %{project_path: project_path}) do
    test_path = Giulia.Tools.RunTests.suggest_test_file(target_file)
    sandbox = PathSandbox.new(project_path)

    case PathSandbox.validate(sandbox, test_path) do
      {:ok, resolved} when is_binary(resolved) ->
        if File.exists?(resolved) do
          "Note: Tests exist at #{test_path}. You may run them with run_tests to verify behavior.\n"
        else
          ""
        end

      _ ->
        ""
    end
  end

  @doc "Build graph-driven regression hint."
  @spec build_regression_hint(map()) :: String.t()
  def build_regression_hint(state) do
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

  @doc "Assess hub risk for a write tool. Returns warning string or nil."
  @spec assess_hub_risk(String.t(), map(), String.t()) :: String.t() | nil
  def assess_hub_risk(tool_name, params, project_path)
      when tool_name in @write_tools do
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

  def assess_hub_risk(_tool_name, _params, _project_path), do: nil

  @doc "Resolve the module name from tool params."
  @spec resolve_module_from_params(String.t(), map(), String.t()) :: String.t() | nil
  def resolve_module_from_params("edit_file", params, project_path) do
    file = params["file"] || params[:file]
    module_from_file_path(file, project_path)
  end

  def resolve_module_from_params("write_file", params, project_path) do
    path = params["path"] || params[:path]
    module_from_file_path(path, project_path)
  end

  def resolve_module_from_params(tool_name, params, _project_path)
      when tool_name in ["patch_function", "write_function"] do
    params["module"] || params[:module]
  end

  def resolve_module_from_params(_, _, _project_path), do: nil

  defp module_from_file_path(nil, _project_path), do: nil

  defp module_from_file_path(path, project_path) do
    case Store.Query.find_module_by_file(project_path, path) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end
end
