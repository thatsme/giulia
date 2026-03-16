defmodule Giulia.Tools.CycleCheck do
  @moduledoc """
  Detect compile-time cyclic dependencies using mix xref.

  Runs `mix xref graph --format cycles` to find modules that form
  compile-time dependency cycles. These cycles cause cascading
  recompilation — touch one file, rebuild half the project.

  Based on dominicletz/elixir-skills cyclic dependencies skill.
  Requires Elixir 1.19+ for accurate results.

  Strategies for breaking cycles:
  - Extract helper module (shared logic both sides need)
  - Move code down (shift function to break direction)
  - Invert dependency (callback/data instead of direct call)
  - Split module (one module, two responsibilities)
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  @behaviour Giulia.Tools.Registry

  # The two xref labels that matter
  @labels ["compile-connected", "compile"]

  @primary_key false
  embedded_schema do
    field(:label, :string, default: "all")
    field(:fail_above, :integer, default: -1)
  end

  @impl true
  def name, do: "cycle_check"

  @impl true
  def description do
    "Detect compile-time cyclic dependencies in the project. " <>
      "Returns cycles found by mix xref. Use label 'compile-connected', " <>
      "'compile', or 'all' (default, runs both). " <>
      "Set fail_above to a number to fail if cycles exceed that count."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        label: %{
          type: "string",
          description: "Which xref label: 'compile-connected', 'compile', or 'all' (runs both)"
        },
        fail_above: %{
          type: "integer",
          description:
            "Fail if cycle count exceeds this number (-1 = no limit, 0 = no cycles allowed)"
        }
      },
      required: []
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:label, :fail_above])
    |> validate_inclusion(:label, ["compile-connected", "compile", "all"])
  end

  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{label: label, fail_above: fail_above}, opts) do
    project_path = Keyword.get(opts, :project_path) || File.cwd!()

    elixir_version =
      case check_elixir_version(project_path) do
        {:ok, version} -> version
        {:error, _} -> "unknown"
      end

    labels_to_check = if label == "all", do: @labels, else: [label]

    results =
      Enum.map(labels_to_check, fn l ->
        {l, run_xref(l, fail_above, project_path)}
      end)

    format_results(results, elixir_version)
  end

  def execute(params, opts) do
    case Giulia.StructuredOutput.parse_map(params, __MODULE__) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  # --- Private ---

  defp check_elixir_version(project_path) do
    try do
      case System.cmd("elixir", ["--version"], cd: project_path, stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/Elixir (\d+)\.(\d+)\.(\d+)/, output) do
            [_, major, minor, _patch] ->
              {major, _} = Integer.parse(major)
              {minor, _} = Integer.parse(minor)

              if major > 1 or (major == 1 and minor >= 19) do
                {:ok, "#{major}.#{minor}"}
              else
                {:error,
                 "⚠ Elixir #{major}.#{minor} detected. " <>
                   "Cycle detection requires Elixir 1.19+ for accurate results. " <>
                   "Earlier versions may report phantom cycles or miss real ones. " <>
                   "Upgrade with: asdf install elixir 1.19.0 (or your version manager)"}
              end

            _ ->
              {:error, "Could not parse Elixir version from: #{String.trim(output)}"}
          end

        {output, _} ->
          {:error, "Failed to check Elixir version: #{String.trim(output)}"}
      end
    rescue
      e -> {:error, "Elixir not found: #{Exception.message(e)}"}
    end
  end

  defp run_xref(label, fail_above, project_path) do
    args = ["xref", "graph", "--format", "cycles", "--label", label]
    args = if fail_above >= 0, do: args ++ ["--fail-above", to_string(fail_above)], else: args

    Logger.info("Running: mix #{Enum.join(args, " ")}")

    try do
      case System.cmd("mix", args, cd: project_path, stderr_to_stdout: true) do
        {output, 0} ->
          cycles = parse_cycles(output)
          {:ok, %{output: output, cycles: cycles, count: length(cycles), passed: true}}

        {output, _exit_code} ->
          cycles = parse_cycles(output)
          {:ok, %{output: output, cycles: cycles, count: length(cycles), passed: false}}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp parse_cycles(output) do
    # mix xref outputs cycles as groups of module names
    # Each cycle block is separated by blank lines
    output
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reject(&String.starts_with?(String.trim(&1), "Compiling"))
    |> chunk_cycles([])
  end

  # Group lines into cycle blocks
  # xref outputs: "Cycle of N modules:\n  ModA\n  ModB\n  ..."
  defp chunk_cycles([], acc), do: Enum.reverse(acc)

  defp chunk_cycles([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      String.contains?(trimmed, "cycle") or String.contains?(trimmed, "Cycle") ->
        # Start of a new cycle block — collect indented module names
        {modules, remaining} = collect_modules(rest, [])
        cycle = %{header: trimmed, modules: modules}
        chunk_cycles(remaining, [cycle | acc])

      true ->
        chunk_cycles(rest, acc)
    end
  end

  defp collect_modules([], acc), do: {Enum.reverse(acc), []}

  defp collect_modules([line | rest] = lines, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {Enum.reverse(acc), rest}

      # Indented line = module in the cycle
      String.starts_with?(line, " ") or String.starts_with?(line, "\t") ->
        collect_modules(rest, [trimmed | acc])

      # Next cycle header or other content
      true ->
        {Enum.reverse(acc), lines}
    end
  end

  defp format_results(results, elixir_version) do
    sections =
      Enum.map(results, fn {label, result} ->
        case result do
          {:ok, %{cycles: cycles, count: count, passed: passed}} ->
            status = if passed, do: "✓ PASS", else: "✗ FAIL"

            cycle_detail =
              if count == 0 do
                "  No cycles found."
              else
                cycles
                |> Enum.with_index(1)
                |> Enum.map(fn {%{header: header, modules: modules}, idx} ->
                  mods = Enum.map(modules, &"      #{&1}") |> Enum.join("\n")
                  "  #{idx}. #{header}\n#{mods}"
                end)
                |> Enum.join("\n\n")
              end

            """
            [#{status}] --label #{label}: #{count} cycle(s)
            #{cycle_detail}
            """

          {:error, reason} ->
            "[✗ ERROR] --label #{label}: #{reason}"
        end
      end)

    total_cycles =
      results
      |> Enum.map(fn
        {_, {:ok, %{count: c}}} -> c
        _ -> 0
      end)
      |> Enum.sum()

    summary =
      if total_cycles == 0 do
        "\n✓ No compile-time cycles detected. Clean dependency graph."
      else
        """

        ⚠ #{total_cycles} total cycle(s) found.

        Strategies to break cycles (prefer minimal changes):
        1. Extract helper module — shared logic both modules need
        2. Move code down — shift function to eliminate one direction
        3. Invert dependency — use callback/data instead of direct call
        4. Split module — separate responsibilities into two modules

        Tip: Struct expansion (%MyStruct{}) creates compile-time deps.
             Use struct(MyStruct, fields) or raw maps to break these.
        """
      end

    {:ok,
     "Cycle Check (Elixir #{elixir_version})\n" <>
       "==================================\n\n" <>
       Enum.join(sections, "\n") <>
       summary}
  end
end
