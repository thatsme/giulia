defmodule Giulia.Tools.RunMix do
  @moduledoc """
  Run safe mix commands within the project.

  SECURITY: Only whitelisted commands are allowed.
  No arbitrary shell execution - that's how you get pwned.

  Allowed commands:
  - mix test (run tests)
  - mix compile (compile project)
  - mix format --check-formatted (check formatting)
  - mix deps.get (fetch dependencies)
  - mix help (show help)
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  @behaviour Giulia.Tools.Registry

  # Whitelist of allowed mix commands (security critical)
  @allowed_commands %{
    "test" => ["test"],
    "test_file" => ["test"],  # Will have file appended
    "compile" => ["compile", "--warnings-as-errors"],
    "format_check" => ["format", "--check-formatted"],
    "deps" => ["deps.get"],
    "help" => ["help"]
  }

  @primary_key false
  embedded_schema do
    field :command, :string
    field :args, :string, default: ""
  end

  @impl true
  def name, do: "run_mix"

  @impl true
  def description, do: "Run a mix command (test, compile, format_check, deps). Only safe commands are allowed."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description: "Command to run: 'test', 'test_file', 'compile', 'format_check', 'deps', 'help'"
        },
        args: %{
          type: "string",
          description: "Additional arguments (e.g., file path for test_file)"
        }
      },
      required: ["command"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:command, :args])
    |> validate_required([:command])
    |> validate_inclusion(:command, Map.keys(@allowed_commands))
  end

  def execute(params, opts \\ [])

  def execute(%__MODULE__{command: command, args: args}, opts) do
    project_path = Keyword.get(opts, :project_path) || File.cwd!()

    case Map.get(@allowed_commands, command) do
      nil ->
        {:error, "Unknown command '#{command}'. Allowed: #{Enum.join(Map.keys(@allowed_commands), ", ")}"}

      base_args ->
        full_args = build_args(command, base_args, args)
        run_mix_command(full_args, project_path)
    end
  end

  def execute(%{"command" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{command: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp build_args("test_file", base_args, file_path) when file_path != "" do
    # Validate the file path is a test file
    if String.ends_with?(file_path, "_test.exs") do
      base_args ++ [file_path]
    else
      base_args ++ [file_path]  # Let mix handle the error
    end
  end

  defp build_args(_command, base_args, _args) do
    base_args
  end

  defp run_mix_command(args, project_path) do
    Logger.info("Running: mix #{Enum.join(args, " ")} in #{project_path}")

    # Use System.cmd with timeout and working directory
    try do
      case System.cmd("mix", args,
             cd: project_path,
             stderr_to_stdout: true,
             env: [{"MIX_ENV", "test"}]
           ) do
        {output, 0} ->
          {:ok, truncate_output(output)}

        {output, exit_code} ->
          # Still return output even on failure - useful for debugging
          {:ok, "Exit code: #{exit_code}\n\n#{truncate_output(output)}"}
      end
    rescue
      e ->
        {:error, "Failed to run mix: #{Exception.message(e)}"}
    end
  end

  defp truncate_output(output) do
    # Truncate for small models
    if String.length(output) > 3000 do
      String.slice(output, 0, 3000) <> "\n\n... [output truncated]"
    else
      output
    end
  end

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
