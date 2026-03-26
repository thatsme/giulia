defmodule Giulia.Tools.PatchFunction do
  @moduledoc """
  Sourceror-based function replacement — the preferred tool for code edits.

  Strategy: Sourceror parses the file to find the function's line range,
  then we do string-level replacement and run Code.format_string! on the result.
  This avoids Sourceror.postwalk → Macro.traverse crashes on Elixir 1.19.

  Key features:
  - Multi-head capture: all contiguous clauses for name/arity → one range
  - Code.format_string! ensures project-consistent formatting
  - Buffer re-sync: triggers Indexer.scan_file after write (stale ETS prevention)
  - Code param injected from fenced ```elixir block by Parser (never JSON-escaped)

  Schema: module, function_name, arity, code (raw Elixir from fenced block)
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Context.{Store, Indexer}
  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field(:module, :string)
    field(:function_name, :string)
    field(:arity, :integer)
    field(:code, :string)
  end

  @impl true
  @spec name() :: String.t()
  def name, do: "patch_function"

  @impl true
  @spec description() :: String.t()
  def description do
    "Replace a function using AST patching. Preferred over edit_file for function replacement. " <>
      "Uses Sourceror to find the function by name/arity and replace it, preserving file formatting."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        module: %{
          type: "string",
          description: "Full module name (e.g., 'Giulia.Inference.Orchestrator')"
        },
        function_name: %{
          type: "string",
          description: "Name of the function to replace (e.g., 'handle_continue')"
        },
        arity: %{
          type: "integer",
          description: "Function arity (number of arguments)"
        },
        code: %{
          type: "string",
          description:
            "Complete new function code including def/defp. Use <payload> tags for this."
        }
      },
      required: ["module", "function_name", "arity", "code"]
    }
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:module, :function_name, :arity, :code])
    |> validate_required([:module, :function_name, :arity, :code])
  end

  @impl true
  @spec execute(map() | %__MODULE__{}, keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(params, opts \\ [])

  def execute(%__MODULE__{} = params, opts) do
    do_patch_function(params.module, params.function_name, params.arity, params.code, opts)
  end

  def execute(%{"module" => _, "function_name" => _, "arity" => _, "code" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{module: _, function_name: _, arity: _, code: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # Catch-all: missing "code" param (model sent action-only without <payload>)
  def execute(params, _opts) when is_map(params) do
    {:error,
     """
     patch_function requires a "code" parameter with the new function body.

     You must use the HYBRID FORMAT with <payload> tags:
     <action>
     {"tool": "patch_function", "parameters": {"module": "#{Map.get(params, "module", "Module")}", "function_name": "#{Map.get(params, "function_name", "func")}", "arity": #{Map.get(params, "arity", 0)}}}
     </action>
     <payload>
     def #{Map.get(params, "function_name", "func")}(...) do
       # your code here
     end
     </payload>

     The code goes in <payload>, NOT in the JSON parameters.
     """}
  end

  # ============================================================================
  # Core Logic — Sourceror-based patching
  # ============================================================================

  defp do_patch_function(module_name, func_name, arity, new_code, opts) do
    require Logger

    try do
      # Step 1: Find the module file via index
      project_path = opts[:project_path]

      case Store.Query.find_module(project_path, module_name) do
        {:ok, %{file: file_path}} ->
          sandbox = get_sandbox(opts)

          case PathSandbox.validate(sandbox, file_path) do
            {:ok, safe_path} ->
              patch_function_in_file(safe_path, func_name, arity, new_code)

            {:error, :sandbox_violation} ->
              {:error, PathSandbox.violation_message(file_path, sandbox)}
          end

        :not_found ->
          {:error, "Module '#{module_name}' not found in project index. Run /scan first."}
      end
    rescue
      e ->
        Logger.error("PatchFunction CRASH: #{Exception.format(:error, e, __STACKTRACE__)}")
        {:error, "Internal error: #{inspect(e)}"}
    end
  end

  defp patch_function_in_file(file_path, func_name, arity, new_code) do
    require Logger
    func_atom = String.to_existing_atom(func_name)
    Logger.info("PatchFunction: Patching #{func_name}/#{arity} in #{file_path}")

    with {:ok, raw_source} <- File.read(file_path),
         # Normalize CRLF → LF before any processing (Windows files have \r\n)
         source = String.replace(raw_source, "\r\n", "\n"),
         {:ok, _valid_ast} <- parse_new_function(new_code),
         {:ok, range} <- find_function_range(source, func_atom, arity) do
      # ATOMIC SURGERY: splice → format → write. If format fails, abort.
      # The file on disk is GUARANTEED to be syntactically valid and formatted.
      new_source = splice_source(source, range, new_code)

      case format_source(new_source) do
        {:ok, formatted} ->
          case File.write(file_path, formatted) do
            :ok ->
              Logger.info("PatchFunction: Successfully patched #{func_name}/#{arity}")
              # Buffer Re-Sync: invalidate stale ETS coordinates immediately
              Indexer.scan_file(file_path)
              {:ok, "Patched #{func_name}/#{arity} in #{Path.basename(file_path)}"}

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end

        {:error, format_error} ->
          # ATOMIC ABORT: formatter failed → do NOT write corrupted code to disk.
          # Return the error so the model can fix its code and retry.
          Logger.error("PatchFunction: ATOMIC ABORT — formatter failed, file NOT modified.")
          Logger.error("PatchFunction: Format error: #{format_error}")

          {:error,
           """
           ATOMIC ABORT: Your code produced a syntax error AFTER splicing into the file.
           The file was NOT modified — it is still in its original state.

           Formatter error: #{format_error}

           Your proposed code:
           #{new_code}

           Fix the syntax error in your code and try patch_function again.
           Do NOT use edit_file — the file has not changed.
           """}
      end
    else
      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, :function_not_found} ->
        {:error, "Function #{func_name}/#{arity} not found in #{Path.basename(file_path)}"}

      {:error, reason} ->
        {:error, "Failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Function Range Finding (Sourceror for range, string-level replacement)
  # ============================================================================

  # Find the line range of a function definition using Sourceror's range metadata.
  # Does NOT use Sourceror.postwalk (crashes with Macro.traverse on Elixir 1.19).
  # Instead, parses to get the AST then manually searches top-level definitions.
  defp find_function_range(source, func_atom, arity) do
    require Logger

    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        case search_defmodule_for_function(ast, func_atom, arity) do
          {:ok, range} ->
            Logger.info(
              "PatchFunction: Found #{func_atom}/#{arity} at lines #{range.start_line}-#{range.end_line}"
            )

            {:ok, range}

          :not_found ->
            {:error, :function_not_found}
        end

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, 1), else: 1
        {:error, "Source parse error at line #{line}: #{message} #{inspect(token)}"}

      {:error, reason} ->
        {:error, "Source parse error: #{inspect(reason)}"}
    end
  end

  # Search inside defmodule body for the target function
  defp search_defmodule_for_function({:defmodule, _meta, [_alias, [do: body]]}, func_atom, arity) do
    search_body_for_function(body, func_atom, arity)
  end

  defp search_defmodule_for_function(
         {:defmodule, _meta, [_alias, [{_do_key, body}]]},
         func_atom,
         arity
       ) do
    search_body_for_function(body, func_atom, arity)
  end

  defp search_defmodule_for_function(_ast, _func_atom, _arity), do: :not_found

  # Multi-Head Block Capture: find ALL contiguous clauses for a function/arity
  # and return a single range spanning from first clause start to last clause end.
  # e.g., `def handle_call(...)` with 5 clauses → one range covering all of them.
  defp search_body_for_function({:__block__, _meta, statements}, func_atom, arity) do
    # Collect ALL matching clause ranges
    ranges =
      Enum.flat_map(statements, fn stmt ->
        case match_function_def(stmt, func_atom, arity) do
          {:ok, range} -> [range]
          :no_match -> []
        end
      end)

    case ranges do
      [] ->
        :not_found

      [single] ->
        {:ok, single}

      [first | _] ->
        last = List.last(ranges)
        {:ok, %{start_line: first.start_line, end_line: last.end_line}}
    end
  end

  # Single-expression module body
  defp search_body_for_function(stmt, func_atom, arity) do
    case match_function_def(stmt, func_atom, arity) do
      {:ok, _} = result -> result
      :no_match -> :not_found
    end
  end

  # Match def/defp with or without guard clause, extract line range
  defp match_function_def(
         {def_type, meta, [{:when, _, [{name, _, args} | _]} | _]},
         func_atom,
         arity
       )
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      extract_range(meta)
    else
      :no_match
    end
  end

  defp match_function_def({def_type, meta, [{name, _, args} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      extract_range(meta)
    else
      :no_match
    end
  end

  defp match_function_def(_node, _func_atom, _arity), do: :no_match

  # Extract start/end line from Sourceror metadata.
  # Prefers :end (the `end` keyword line) over :end_of_expression.
  defp extract_range(meta) when is_list(meta) do
    start_line = Keyword.get(meta, :line, nil)
    # Sourceror stores end location in :end key (the `end` keyword)
    end_info = Keyword.get(meta, :end, nil)
    end_line = if is_list(end_info), do: Keyword.get(end_info, :line, nil), else: nil

    # Fallback to :end_of_expression only if :end is missing
    end_line = end_line || extract_eoe_line(meta)

    cond do
      start_line && end_line ->
        {:ok, %{start_line: start_line, end_line: end_line}}

      start_line ->
        {:ok, %{start_line: start_line, end_line: nil}}

      true ->
        :no_match
    end
  end

  defp extract_range(_), do: :no_match

  defp extract_eoe_line(meta) do
    case Keyword.get(meta, :end_of_expression, nil) do
      eoe when is_list(eoe) -> Keyword.get(eoe, :line, nil)
      _ -> nil
    end
  end

  # ============================================================================
  # String-Level Splice (replaces lines start_line..end_line inclusive)
  # ============================================================================

  # Splice new code into source, replacing lines start_line..end_line (1-indexed, inclusive).
  # Does NOT indent — Code.format_string! handles indentation after splice.
  defp splice_source(source, %{start_line: start_line, end_line: end_line}, new_code) do
    require Logger
    lines = String.split(source, "\n")
    total_lines = length(lines)

    actual_end = end_line || find_function_end(lines, start_line)

    # Safety: clamp end_line to file bounds (never eat past defmodule's end)
    actual_end = min(actual_end, total_lines)

    # Safety: verify the line at actual_end contains `end` (for Sourceror ranges)
    actual_end = verify_end_line(lines, actual_end)

    Logger.info(
      "PatchFunction: Splicing lines #{start_line}..#{actual_end} (total=#{total_lines})"
    )

    # before = lines 1..(start_line - 1)
    # after  = lines (actual_end + 1)..total
    before = Enum.take(lines, start_line - 1)
    after_lines = Enum.drop(lines, actual_end)
    new_lines = String.split(String.trim_trailing(new_code), "\n")

    Enum.join(before ++ new_lines ++ after_lines, "\n")
  end

  # Walk backward from end_line to find the actual `end` keyword.
  # Protects against :end_of_expression pointing past the function's `end`.
  defp verify_end_line(lines, end_line) do
    line_content = Enum.at(lines, end_line - 1, "")

    if String.trim(line_content) =~ ~r/^end\b/ do
      end_line
    else
      # Search backward up to 5 lines for the `end` keyword
      Enum.find((end_line - 1)..max(end_line - 5, 1)//-1, end_line, fn idx ->
        String.trim(Enum.at(lines, idx - 1, "")) =~ ~r/^end\b/
      end)
    end
  end

  # Fallback: find the matching `end` for a def/defp starting at start_line
  defp find_function_end(lines, start_line) do
    lines
    |> Enum.drop(start_line - 1)
    |> Enum.with_index(start_line)
    |> Enum.reduce_while(0, fn {line, idx}, depth ->
      trimmed = String.trim(line)
      # Skip empty lines and comments
      if trimmed == "" or String.starts_with?(trimmed, "#") do
        {:cont, depth}
      else
        opens = length(Regex.scan(~r/\b(do)\b/, trimmed))
        closes = length(Regex.scan(~r/\bend\b/, trimmed))
        new_depth = depth + opens - closes

        if new_depth <= 0 and idx > start_line do
          {:halt, idx}
        else
          {:cont, new_depth}
        end
      end
    end)
  end

  defp parse_new_function(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, 1), else: 1
        col = if is_list(meta), do: Keyword.get(meta, :column, 1), else: 1
        lines = String.split(code, "\n")
        context = extract_error_context(lines, line)

        {:error,
         """
         SYNTAX ERROR in your proposed code at line #{line}, column #{col}:
         #{message} #{inspect(token)}

         YOUR CODE (showing error location):
         #{context}

         FULL CODE YOU SENT:
         #{code}

         Fix the syntax error and try again.
         """}
    end
  end

  # (Sourceror.postwalk removed — crashes with Macro.traverse on Elixir 1.19)
  # Replaced by find_function_range + splice_source above.

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_source(source) do
    try do
      formatted = IO.iodata_to_binary(Code.format_string!(source))
      # Ensure trailing newline
      formatted = if String.ends_with?(formatted, "\n"), do: formatted, else: formatted <> "\n"
      {:ok, formatted}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_error_context(lines, error_line) do
    start_line = max(1, error_line - 3)
    end_line = min(length(lines), error_line + 3)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_, idx} -> idx >= start_line and idx <= end_line end)
    |> Enum.map(fn {line, idx} ->
      marker = if idx == error_line, do: ">>> ", else: "    "
      "#{marker}#{idx}: #{line}"
    end)
    |> Enum.join("\n")
  end

  defp parse_params(params) do
    changeset = changeset(params)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp get_sandbox(opts) do
    case Keyword.get(opts, :sandbox) do
      nil -> PathSandbox.new(File.cwd!())
      sandbox -> sandbox
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
