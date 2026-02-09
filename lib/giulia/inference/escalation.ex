defmodule Giulia.Inference.Escalation do
  @moduledoc """
  Senior Architect escalation logic for compilation error recovery.

  Handles the hybrid escalation protocol:
  - Builds prompts for the Senior Architect (Groq/Gemini)
  - Calls cloud providers for surgical fixes
  - Parses LINE:N/CODE: legacy format responses
  - Applies line-level fixes to files

  Stateless module — no GenServer coupling. The Orchestrator's
  `handle_continue({:escalate, ...})` callback manages state transitions.
  """

  require Logger

  @doc """
  Build the v2 Senior Architect prompt requesting hybrid <action> + <payload> format.
  """
  def build_prompt(target_file, file_content, errors) do
    """
    You are the Senior Elixir Architect. Fix this compilation error.

    FILE: #{target_file || "unknown"}

    ERROR:
    #{String.slice(errors, 0, 1500)}

    CURRENT FILE (with line numbers):
    #{add_line_numbers(file_content)}

    RESPONSE FORMAT — Choose ONE:

    OPTION A (for function-level fixes — PREFERRED):
    <action>
    {"tool": "patch_function", "parameters": {"module": "Module.Name", "function_name": "func", "arity": 2}}
    </action>

    ```elixir
    def func(arg1, arg2) do
      # your corrected function code here
    end
    ```

    OPTION B (for single-line fixes):
    LINE:NUMBER
    CODE:THE CORRECTED LINE CONTENT

    RULES:
    - Fix ONLY the compilation error, nothing else
    - For Option A: code goes in ```elixir fenced block after </action>
    - For Option A: module name must be the FULL module name (e.g., Giulia.Inference.Orchestrator)
    - For Option B: NUMBER is the line number, CODE is the exact corrected line
    - Do NOT add any text after the closing ```
    - Output ONLY the fix, no explanations
    """
  end

  @doc """
  Call cloud provider for Senior Architect consultation.
  Tries Groq first (LPU speed), falls back to Gemini.
  Returns `{:ok, provider_name, response}` or `{:error, reason}`.
  """
  def call(prompt) do
    messages = [
      %{
        role: "system",
        content:
          "You are a Senior Elixir Architect. Be precise and surgical. Output only the fix, no explanations."
      },
      %{role: "user", content: prompt}
    ]

    cond do
      Giulia.Provider.Groq.available?() ->
        Logger.info("Calling Groq (Llama 3.3 70B) as Senior Architect...")

        case Giulia.Provider.Groq.chat(messages, [], timeout: 60_000) do
          {:ok, response} ->
            {:ok, "Groq Llama 3.3 70B", response.content || "No response content"}

          {:error, reason} ->
            Logger.warning("Groq failed: #{inspect(reason)}, trying Gemini fallback...")
            try_gemini(messages)
        end

      Giulia.Provider.Gemini.available?() ->
        Logger.info("Calling Gemini as Senior Architect (Groq not available)...")
        try_gemini(messages)

      true ->
        Logger.warning("No escalation provider available - check GROQ_API_KEY or GEMINI_API_KEY")
        {:error, :no_escalation_provider}
    end
  end

  @doc """
  Gemini fallback for escalation.
  Returns `{:ok, provider_name, response}` or `{:error, reason}`.
  """
  def try_gemini(messages) do
    case Giulia.Provider.Gemini.chat(messages, [], timeout: 60_000) do
      {:ok, response} ->
        {:ok, "Gemini 2.0 Flash", response.content || "No response content"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse legacy LINE:N / CODE: format from Senior Architect response.
  Returns `{:ok, line_num, fixed_line}` or `{:error, reason}`.
  """
  def parse_line_fix(response) do
    cleaned =
      response
      |> String.replace(~r/```\w*\s*/, "")
      |> String.trim()

    line_match = Regex.run(~r/LINE:\s*(\d+)/i, cleaned)
    code_match = Regex.run(~r/CODE:(.*)$/im, cleaned)

    case {line_match, code_match} do
      {[_, line_str], [_, code]} ->
        line_num = String.to_integer(String.trim(line_str))
        {:ok, line_num, code}

      {nil, _} ->
        Logger.error("No LINE: found in response: #{cleaned}")
        {:error, :no_line_number}

      {_, nil} ->
        Logger.error("No CODE: found in response: #{cleaned}")
        {:error, :no_code_content}
    end
  end

  @doc """
  Apply a line fix: replace line N in file with fixed content.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def apply_line_fix(file_path, line_num, fixed_line, sandbox) do
    safe_path =
      case Giulia.Core.PathSandbox.validate(sandbox, file_path) do
        {:ok, path} -> path
        {:error, _} -> file_path
      end

    case File.read(safe_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        if line_num > 0 and line_num <= length(lines) do
          new_lines = List.replace_at(lines, line_num - 1, fixed_line)
          new_content = Enum.join(new_lines, "\n")

          case File.write(safe_path, new_content) do
            :ok ->
              {:ok, "Line #{line_num} fixed in #{Path.basename(safe_path)}"}

            {:error, reason} ->
              {:error, "Write failed: #{inspect(reason)}"}
          end
        else
          {:error, "Invalid line number: #{line_num} (file has #{length(lines)} lines)"}
        end

      {:error, reason} ->
        {:error, "Read failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Add line numbers to file content for easier reference in prompts.
  """
  def add_line_numbers(nil), do: "(could not read file)"

  def add_line_numbers(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} -> "#{String.pad_leading(Integer.to_string(num), 4)}: #{line}" end)
    |> Enum.join("\n")
  end
end
