defmodule Giulia.Core.ProjectContext.Constitution do
  @moduledoc """
  Constitution (GIULIA.md) loading and parsing.

  Extracts structured data from the project's GIULIA.md file:
  rules, taboos, preferred patterns, tech stack, and provider preference.

  All functions are pure — no state, no side effects beyond file reads.

  Extracted from `Core.ProjectContext` (Build 128).
  """

  require Logger

  @spec load(String.t()) :: map()
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        Logger.warning("Could not load GIULIA.md: #{inspect(reason)}")
        %{raw: nil, rules: [], taboos: [], patterns: []}
    end
  end

  @spec parse(String.t()) :: map()
  def parse(content) do
    %{
      raw: content,
      rules: extract_section(content, "Architectural Guidelines"),
      taboos: extract_section(content, "Taboos"),
      patterns: extract_section(content, "Preferred Patterns"),
      tech_stack: extract_tech_stack(content)
    }
  end

  @spec determine_provider(map() | nil) :: :cloud | :auto
  def determine_provider(constitution) do
    case constitution[:tech_stack] do
      %{framework: "Phoenix"} -> :cloud
      _ -> :auto
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp extract_section(content, section_name) do
    regex = ~r/## #{section_name}\s*\n((?:[-*].*\n?)*)/

    case Regex.run(regex, content) do
      [_, bullets] ->
        bullets
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, ["-", "*"]))
        |> Enum.map(&String.replace_prefix(&1, "- ", ""))
        |> Enum.map(&String.replace_prefix(&1, "* ", ""))

      nil ->
        []
    end
  end

  defp extract_tech_stack(content) do
    language = extract_field(content, "Language")
    framework = extract_field(content, "Framework")
    %{language: language, framework: framework}
  end

  defp extract_field(content, field) do
    regex = ~r/\*\*#{field}\*\*:\s*(.+)/

    case Regex.run(regex, content) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
