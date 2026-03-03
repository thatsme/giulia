defmodule Giulia.Inference.Verification do
  @moduledoc """
  Compilation verification and result parsing.

  Parses mix compile output to classify results as success, warnings,
  or errors. Builds BUILD GREEN observations for the inference loop.
  Checks baseline project compilation state.

  Pure-functional module — no GenServer coupling.
  """

  require Logger

  alias Giulia.Prompt.Builder
  alias Giulia.Tools.Registry

  @doc """
  Parse mix compile output to determine success/warnings/errors.
  Returns `:success`, `{:warnings, text}`, or `{:error, text}`.
  """
  def parse_compile_result(output) do
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

  @doc """
  Extract specific error lines from compile output for cleaner feedback.
  """
  def extract_compile_errors(output) do
    specific_errors =
      output
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(line, "error") or
          String.contains?(line, "Error") or
          String.contains?(line, "** (") or
          String.contains?(line, "undefined") or
          String.match?(line, ~r/^\s+\|/)
      end)
      |> Enum.take(30)
      |> Enum.join("\n")

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

  @doc """
  Extract warning lines from compile output.
  """
  def extract_compile_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "warning:"))
    |> Enum.take(10)
    |> Enum.join("\n")
  end

  @doc """
  Check baseline project state before starting work.
  Returns `:clean`, `:dirty`, or `:unknown`.
  """
  def check_baseline(project_path, tool_opts) do
    if project_path do
      Logger.info("Checking baseline compilation state...")

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

  @doc """
  Build the BUILD GREEN observation string.
  Returns the observation text (caller manages state).
  """
  def build_green_observation(tool_name, result, warnings, test_hint, test_summary) do
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

    """
    #{Builder.format_observation(tool_name, result)}

    ✅ BUILD GREEN. mix compile succeeded.
    #{auto_regress_section}#{test_hint}Your task is COMPLETE. Use the "respond" tool NOW to tell the user what you did.
    Do NOT make any more changes. Do NOT patch the same function again.
    #{warnings_section}
    """
  end
end
