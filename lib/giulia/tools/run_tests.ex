defmodule Giulia.Tools.RunTests do
  @moduledoc """
  Structured ExUnit test runner with failure parsing.

  Unlike `run_mix "test"`, this tool parses ExUnit CLI output into
  actionable failure maps that small LLMs can reason about.

  Features:
  - Structured failure parsing (file, line, assertion, left/right values)
  - Source context around failure lines (3 lines above/below)
  - 3-layer truncation (per-field, per-count, total)
  - Test file discovery helper (lib path -> test path)
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  @behaviour Giulia.Tools.Registry

  # ExUnit CLI output regex patterns
  @failure_header ~r/^\s+(\d+)\) test (.+) \(([^)]+)\)/m
  @failure_location ~r/^\s+(test\/\S+):(\d+)/m
  @assertion_type ~r/^\s+Assertion with (.+) failed/m
  @code_line ~r/^\s+code:\s+(.+)/m
  @left_value ~r/^\s+left:\s+(.+)/m
  @right_value ~r/^\s+right:\s+(.+)/m
  @message_line ~r/^\s+message:\s+"(.+)"/m
  @summary_line ~r/(\d+) tests?,\s*(\d+) failures?(?:,\s*(\d+) excluded)?/

  # Truncation limits
  @max_field_length 100
  @max_detailed_failures 3
  @max_total_chars 3000

  @primary_key false
  embedded_schema do
    field(:file, :string)
    field(:test_name, :string)
  end

  @impl true
  def name, do: "run_tests"

  @impl true
  def description,
    do: "Run ExUnit tests with structured failure analysis. Preferred over run_mix for testing."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        file: %{
          type: "string",
          description: "Test file path. Omit for all."
        },
        test_name: %{
          type: "string",
          description: "Filter by test name pattern"
        }
      },
      required: []
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:file, :test_name])
  end

  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{file: file, test_name: test_name}, opts) do
    project_path = Keyword.get(opts, :project_path) || File.cwd!()
    run_tests(file, test_name, project_path)
  end

  def execute(%{"file" => _, "test_name" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # Handle partial params (both fields are optional)
  def execute(%{} = params, opts) do
    case parse_params(stringify_keys(params)) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # ============================================================================
  # Test File Discovery
  # ============================================================================

  @doc """
  Suggest the conventional test file path for a source file.

  ## Examples

      iex> RunTests.suggest_test_file("lib/giulia/client.ex")
      "test/giulia/client_test.exs"

      iex> RunTests.suggest_test_file("lib/giulia.ex")
      "test/giulia_test.exs"
  """
  @spec suggest_test_file(String.t()) :: String.t()
  def suggest_test_file(source_path) do
    # Extract the lib-relative portion even from absolute paths
    rel =
      case Regex.run(~r"(lib/.+)$", source_path) do
        [_, match] -> match
        nil -> source_path
      end

    rel
    |> String.replace_prefix("lib/", "test/")
    |> String.replace_suffix(".ex", "_test.exs")
  end

  # ============================================================================
  # Test Execution
  # ============================================================================

  defp run_tests(file, test_name, project_path) do
    args = build_args(file, test_name)
    Logger.info("Running: mix #{Enum.join(args, " ")} in #{project_path}")

    try do
      case System.cmd("mix", args,
             cd: project_path,
             stderr_to_stdout: true,
             env: [{"MIX_ENV", "test"}]
           ) do
        {output, 0} ->
          {:ok, format_success(output)}

        {output, _exit_code} ->
          # Check for compilation error first (different from test failure)
          if compilation_error?(output) do
            {:ok, format_compilation_error(output)}
          else
            {:ok, format_test_failures(output, project_path)}
          end
      end
    rescue
      e ->
        {:error, "Failed to run tests: #{Exception.message(e)}"}
    end
  end

  defp build_args(file, test_name) do
    args = ["test"]
    args = if file && file != "", do: args ++ [file], else: args

    args =
      if test_name && test_name != "",
        do: args ++ ["--only", "test_name:#{test_name}"],
        else: args

    args
  end

  # ============================================================================
  # Output Parsing
  # ============================================================================

  defp compilation_error?(output) do
    String.contains?(output, "** (") or
      Regex.match?(~r/^.*error\[.*\]/m, output) or
      String.contains?(output, "compile error")
  end

  defp format_compilation_error(output) do
    truncate_total("""
    COMPILATION ERROR (tests could not run):

    #{String.slice(output, 0, 2500)}
    """)
  end

  defp format_success(output) do
    case Regex.run(@summary_line, output) do
      [_, total, "0"] ->
        "ALL TESTS PASSED: #{total} tests, 0 failures"

      [_, total, "0", excluded] ->
        "ALL TESTS PASSED: #{total} tests, 0 failures, #{excluded} excluded"

      _ ->
        # Fallback: just report success with raw summary
        summary_line =
          output
          |> String.split("\n")
          |> Enum.find("Tests passed", &Regex.match?(@summary_line, &1))

        "ALL TESTS PASSED: #{String.trim(summary_line)}"
    end
  end

  defp format_test_failures(output, project_path) do
    # Parse the summary line
    summary =
      case Regex.run(@summary_line, output) do
        [_, total, failures] ->
          {t, _} = Integer.parse(total)
          {f, _} = Integer.parse(failures)
          passed = t - f
          "TEST RESULTS: #{total} total, #{passed} passed, #{failures} failed"

        [_, total, failures, excluded] ->
          {t, _} = Integer.parse(total)
          {f, _} = Integer.parse(failures)
          {e, _} = Integer.parse(excluded)
          passed = t - f - e

          "TEST RESULTS: #{total} total, #{passed} passed, #{failures} failed, #{excluded} excluded"

        _ ->
          "TEST RESULTS: failures detected"
      end

    # Split output into individual failure blocks
    failures = parse_failure_blocks(output)
    total_failures = length(failures)

    # Format first N failures in detail, rest as one-liners
    {detailed, rest} = Enum.split(failures, @max_detailed_failures)

    detailed_text =
      detailed
      |> Enum.with_index(1)
      |> Enum.map(fn {failure, idx} ->
        format_single_failure(failure, idx, total_failures, project_path)
      end)
      |> Enum.join("\n\n")

    rest_text =
      if rest != [] do
        rest_lines =
          rest
          |> Enum.with_index(@max_detailed_failures + 1)
          |> Enum.map(fn {failure, idx} ->
            "FAILURE #{idx}/#{total_failures}: #{failure.test_name} (#{failure.module}) - #{failure.file}:#{failure.line}"
          end)
          |> Enum.join("\n")

        "\n\n" <> rest_lines
      else
        ""
      end

    truncate_total(summary <> "\n\n" <> detailed_text <> rest_text)
  end

  defp parse_failure_blocks(output) do
    # Split on failure headers (e.g., "  1) test adds two numbers (MyApp.MathTest)")
    blocks =
      Regex.split(~r/(?=^\s+\d+\) test )/m, output)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.filter(&Regex.match?(@failure_header, &1))

    Enum.map(blocks, &parse_single_failure/1)
  end

  defp parse_single_failure(block) do
    %{
      test_name: extract_match(@failure_header, block, 2),
      module: extract_match(@failure_header, block, 3),
      file: extract_match(@failure_location, block, 1),
      line: extract_match(@failure_location, block, 2),
      assertion: extract_match(@assertion_type, block, 1),
      code: extract_match(@code_line, block, 1),
      left: truncate_field(extract_match(@left_value, block, 1)),
      right: truncate_field(extract_match(@right_value, block, 1)),
      message: extract_match(@message_line, block, 1),
      raw: String.slice(block, 0, 200)
    }
  end

  defp extract_match(regex, text, group) do
    case Regex.run(regex, text) do
      nil -> nil
      matches when length(matches) > group -> Enum.at(matches, group)
      _ -> nil
    end
  end

  defp format_single_failure(failure, idx, total, project_path) do
    # Build parts list conditionally — Elixir if blocks don't rebind outer scope
    context =
      if failure.file && failure.line do
        read_source_context(failure.file, failure.line, project_path)
      end

    parts =
      [
        "FAILURE #{idx}/#{total}:",
        "  Test: \"#{failure.test_name || "unknown"}\" (#{failure.module || "unknown"})"
      ] ++
        if_line(failure.file && failure.line, "  File: #{failure.file}:#{failure.line}") ++
        if_line(failure.assertion, "  Assertion: #{failure.assertion}") ++
        if_line(failure.left, "  Got (left): #{failure.left}") ++
        if_line(failure.right, "  Expected (right): #{failure.right}") ++
        if_line(failure.code, "  Code: #{failure.code}") ++
        if_line(failure.message, "  Message: #{failure.message}") ++
        if(context, do: ["\n  Test code:", context], else: [])

    Enum.join(parts, "\n")
  end

  defp if_line(nil, _text), do: []
  defp if_line(false, _text), do: []
  defp if_line(_, text), do: [text]

  # ============================================================================
  # Source Context
  # ============================================================================

  defp read_source_context(file, line_str, project_path) do
    line_num =
      if is_binary(line_str) do
        case Integer.parse(line_str) do
          {n, _} -> n
          :error -> 0
        end
      else
        line_str
      end

    full_path = Path.join(project_path, file)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        start_line = max(1, line_num - 3)
        end_line = min(length(lines), line_num + 3)

        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {_, idx} -> idx >= start_line and idx <= end_line end)
        |> Enum.map(fn {line, idx} ->
          marker = if idx == line_num, do: "  >>  ", else: "      "
          "#{marker}#{idx}| #{line}"
        end)
        |> Enum.join("\n")

      {:error, _} ->
        nil
    end
  end

  # ============================================================================
  # Truncation
  # ============================================================================

  defp truncate_field(nil), do: nil

  defp truncate_field(value) when byte_size(value) > @max_field_length do
    String.slice(value, 0, @max_field_length) <> "..."
  end

  defp truncate_field(value), do: value

  defp truncate_total(text) when byte_size(text) > @max_total_chars do
    String.slice(text, 0, @max_total_chars) <> "\n\n... [output truncated]"
  end

  defp truncate_total(text), do: text

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_params(params) do
    changeset = changeset(params)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
