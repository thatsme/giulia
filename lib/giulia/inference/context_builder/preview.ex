defmodule Giulia.Inference.ContextBuilder.Preview do
  @moduledoc """
  Approval previews: write, edit, and function diffs.
  """

  alias Giulia.Context.Store
  alias Giulia.Inference.ContextBuilder.Helpers
  alias Giulia.Utils.Diff

  @doc "Generate a preview for the approval request."
  @spec generate_preview(String.t(), map(), map()) :: String.t()
  def generate_preview(tool_name, params, state) do
    case tool_name do
      "write_file" ->
        generate_write_preview(params, state)

      "edit_file" ->
        generate_edit_preview(params, state)

      "write_function" ->
        generate_function_preview(params, state)

      "patch_function" ->
        generate_function_preview(params, state)

      "run_tests" ->
        file = params["file"] || params[:file]
        test_name = params["test_name"] || params[:test_name]

        cond do
          file && test_name -> "Run tests in #{file} matching '#{test_name}'"
          file -> "Run tests in #{file}"
          test_name -> "Run all tests matching '#{test_name}'"
          true -> "Run ALL project tests"
        end

      _ ->
        "Tool: #{tool_name}\nParams: #{inspect(params, pretty: true, limit: 500)}"
    end
  end

  # ============================================================================
  # Preview Generators
  # ============================================================================

  defp generate_write_preview(params, state) do
    path = params["path"] || params[:path]
    content = params["content"] || params[:content] || ""

    resolved_path = Helpers.resolve_tool_path(path, state)

    case File.read(resolved_path) do
      {:ok, existing_content} ->
        Diff.colorized(existing_content, content, file_path: path)

      {:error, :enoent} ->
        Diff.preview_new(content, file_path: path)

      {:error, _} ->
        Diff.preview_new(content, file_path: path)
    end
  end

  defp generate_edit_preview(params, state) do
    file = params["file"] || params[:file] || params["path"] || params[:path]
    old_text = params["old_text"] || params[:old_text] || ""
    new_text = params["new_text"] || params[:new_text] || ""

    resolved_path = Helpers.resolve_tool_path(file, state)

    case File.read(resolved_path) do
      {:ok, content} ->
        if String.contains?(content, old_text) do
          new_content = String.replace(content, old_text, new_text, global: false)
          Diff.colorized(content, new_content, file_path: file)
        else
          "File: #{file}\n\nold_text not found in file:\n#{String.slice(old_text, 0, 200)}"
        end

      {:error, _} ->
        "File: #{file}\n\nCould not read file to generate preview."
    end
  end

  defp generate_function_preview(params, state) do
    module = params["module"] || params[:module]
    func_name = params["function_name"] || params[:function_name]
    arity = params["arity"] || params[:arity]
    new_code = params["code"] || params[:code] || ""

    case Store.find_module(state.project_path, module) do
      {:ok, %{file: file_path}} ->
        resolved = Helpers.resolve_tool_path(file_path, state)

        case File.read(resolved) do
          {:ok, content} ->
            old_code = extract_old_function(content, func_name, arity)

            if old_code do
              diff = Diff.colorized(old_code, new_code, file_path: Path.basename(file_path))

              """
              Module: #{module}
              Function: #{func_name}/#{arity}
              File: #{Path.basename(file_path)}

              #{diff}
              """
            else
              """
              Module: #{module}
              Function: #{func_name}/#{arity} (new)
              File: #{Path.basename(file_path)}

              === NEW FUNCTION CODE ===
              #{new_code}
              """
            end

          {:error, _} ->
            "Module: #{module}\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
        end

      :not_found ->
        "Module: #{module} (not found in index)\nFunction: #{func_name}/#{arity}\n\nNew code:\n#{new_code}"
    end
  end

  # ============================================================================
  # Function Extraction (Sourceror-based)
  # ============================================================================

  defp extract_old_function(content, func_name, arity) do
    source = String.replace(content, "\r\n", "\n")
    func_atom = String.to_existing_atom(func_name)

    arity =
      if is_binary(arity) do
        case Integer.parse(arity) do
          {n, _} -> n
          :error -> 0
        end
      else
        arity
      end

    case Sourceror.parse_string(source) do
      {:ok, {:defmodule, _meta, [_alias, [do: body]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      {:ok, {:defmodule, _meta, [_alias, [{_do_key, body}]]}} ->
        extract_function_from_body(source, body, func_atom, arity)

      _ ->
        nil
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "extract_old_function failed for #{func_name}/#{arity}: #{Exception.message(e)}"
      )

      nil
  end

  defp extract_function_from_body(source, {:__block__, _meta, statements}, func_atom, arity) do
    ranges =
      Enum.flat_map(statements, fn stmt ->
        case match_func_def(stmt, func_atom, arity) do
          {:ok, range} -> [range]
          _ -> []
        end
      end)

    case ranges do
      [] ->
        nil

      [first | _] ->
        last = List.last(ranges)
        lines = String.split(source, "\n")
        end_line = min(last.end_line || length(lines), length(lines))

        lines
        |> Enum.slice((first.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")
    end
  end

  defp extract_function_from_body(source, stmt, func_atom, arity) do
    case match_func_def(stmt, func_atom, arity) do
      {:ok, range} ->
        lines = String.split(source, "\n")
        end_line = min(range.end_line || length(lines), length(lines))

        lines
        |> Enum.slice((range.start_line - 1)..(end_line - 1))
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  defp match_func_def({def_type, meta, [{:when, _, [{name, _, args} | _]} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def({def_type, meta, [{name, _, args} | _]}, func_atom, arity)
       when def_type in [:def, :defp] and is_atom(name) do
    if name == func_atom and length(args || []) == arity do
      start_line = Keyword.get(meta, :line)
      end_info = Keyword.get(meta, :end)
      end_line = if is_list(end_info), do: Keyword.get(end_info, :line), else: nil
      if start_line, do: {:ok, %{start_line: start_line, end_line: end_line}}, else: :no_match
    else
      :no_match
    end
  end

  defp match_func_def(_, _, _), do: :no_match
end
