defmodule Giulia.Inference.BulkReplace do
  @moduledoc """
  Batch find-and-replace across multiple files.

  Supports both literal string matching and regex patterns.
  Includes diagnostic feedback when patterns don't match.

  Pure-functional module — takes data, returns results. No GenServer coupling.
  """

  require Logger

  alias Giulia.Inference.Transaction

  @doc """
  Execute a bulk_replace operation.

  Returns `{:ok, observation, new_tx, modified_files, meta}` or `{:error, reason}`.

  Options:
    - `:project_path` — required
    - `:resolve_fn` — `fn path -> resolved_path end`
    - `:modified_files` — existing MapSet of modified files
  """
  @spec execute(map(), Giulia.Inference.Transaction.t(), keyword()) ::
          {:ok, String.t(), Giulia.Inference.Transaction.t(), MapSet.t(), map()}
          | {:error, String.t()}
  def execute(params, tx, opts) do
    pattern = params["pattern"] || params[:pattern]
    replacement = params["replacement"] || params[:replacement]
    file_list = params["file_list"] || params[:file_list] || []
    use_regex = params["regex"] || params[:regex] || false

    cond do
      is_nil(pattern) or pattern == "" ->
        {:error, "Missing required parameter: pattern"}

      is_nil(replacement) ->
        {:error, "Missing required parameter: replacement"}

      file_list == [] ->
        {:error, "file_list is empty. Use get_impact_map first to find dependents."}

      true ->
        run(pattern, replacement, file_list, use_regex, tx, opts)
    end
  end

  @doc false
  def run(pattern, replacement, file_list, use_regex, tx, opts) do
    resolve_fn = Keyword.fetch!(opts, :resolve_fn)
    modified_files = Keyword.get(opts, :modified_files, MapSet.new())

    # Compile the regex if needed
    regex =
      if use_regex do
        case Regex.compile(pattern) do
          {:ok, r} -> r
          {:error, _} -> nil
        end
      else
        nil
      end

    if use_regex and is_nil(regex) do
      {:error, "Invalid regex pattern: #{pattern}"}
    else
      # Process each file
      results =
        Enum.map(file_list, fn file_path ->
          resolved_path = resolve_fn.(file_path)

          content =
            case Map.get(tx.staging_buffer, resolved_path) do
              nil ->
                case File.read(resolved_path) do
                  {:ok, c} -> c
                  {:error, reason} -> {:error, "Cannot read #{file_path}: #{inspect(reason)}"}
                end

              staged ->
                staged
            end

          case content do
            {:error, _} = err ->
              {file_path, resolved_path, err}

            text ->
              count =
                if regex do
                  length(Regex.scan(regex, text))
                else
                  parts = String.split(text, pattern)
                  length(parts) - 1
                end

              if count > 0 do
                new_content =
                  if regex do
                    Regex.replace(regex, text, replacement)
                  else
                    String.replace(text, pattern, replacement)
                  end

                {file_path, resolved_path, {:replaced, count, new_content}}
              else
                {file_path, resolved_path, :no_match}
              end
          end
        end)

      # Stage all successful replacements
      {tx, modified_files, staged, skipped, errors} =
        Enum.reduce(results, {tx, modified_files, [], [], []}, fn
          {file, resolved, {:replaced, count, new_content}}, {acc_tx, acc_mf, s, sk, e} ->
            new_tx = Transaction.backup_original(acc_tx, resolved)
            staging_buffer = Map.put(new_tx.staging_buffer, resolved, new_content)
            new_tx = %{new_tx | staging_buffer: staging_buffer}
            new_mf = MapSet.put(acc_mf, resolved)
            {new_tx, new_mf, [{file, count} | s], sk, e}

          {file, _resolved, :no_match}, {acc_tx, acc_mf, s, sk, e} ->
            {acc_tx, acc_mf, s, [file | sk], e}

          {file, _resolved, {:error, reason}}, {acc_tx, acc_mf, s, sk, e} ->
            {acc_tx, acc_mf, s, sk, [{file, reason} | e]}
        end)

      # Build summary
      staged_summary =
        staged
        |> Enum.reverse()
        |> Enum.map_join("\n", fn {file, count} ->
          "  [STAGED] #{Path.basename(file)} (#{count} replacement#{if count > 1, do: "s", else: ""})"
        end)

      skipped_summary =
        if skipped != [] do
          "\nSkipped (no matches):\n" <>
            Enum.map_join(Enum.reverse(skipped), "\n", &"  - #{Path.basename(&1)}")
        else
          ""
        end

      error_summary =
        if errors != [] do
          "\nErrors:\n" <>
            Enum.map_join(Enum.reverse(errors), "\n", fn {f, r} ->
              "  - #{Path.basename(f)}: #{r}"
            end)
        else
          ""
        end

      total_replacements = Enum.reduce(staged, 0, fn {_, c}, acc -> acc + c end)
      staged_count = map_size(tx.staging_buffer)

      # Diagnostic feedback when 0 matches
      diagnostic =
        if staged == [] and skipped != [] do
          broad_pattern = extract_broad_pattern(pattern)
          diagnose(broad_pattern, file_list, resolve_fn, tx.staging_buffer)
        else
          ""
        end

      observation =
        if staged == [] do
          """
          [BULK_REPLACE] FAILED: '#{pattern}' → '#{replacement}'
          0 files matched the exact pattern '#{pattern}' across #{length(file_list)} files.
          #{diagnostic}#{error_summary}

          HINT: Your pattern must match the EXACT text in the source code. Use a shorter, simpler pattern.
          """
        else
          """
          [BULK_REPLACE] '#{pattern}' → '#{replacement}'
          #{length(staged)} file(s) staged, #{length(skipped)} skipped, #{length(errors)} error(s)
          Total replacements: #{total_replacements}

          Staged:
          #{staged_summary}#{skipped_summary}#{error_summary}

          Currently staging #{staged_count} file(s) total. Use commit_changes to flush to disk.
          """
        end

      Logger.info("BULK_REPLACE: #{length(staged)} files staged, #{length(skipped)} skipped")

      {:ok, String.trim(observation), tx, modified_files,
       %{staged: staged, total_replacements: total_replacements,
         pattern: pattern, replacement: replacement, file_count: length(file_list)}}
    end
  end

  @doc """
  Extract a broader search term from a failed pattern for diagnostics.
  """
  @spec extract_broad_pattern(String.t()) :: String.t()
  def extract_broad_pattern(pattern) do
    cond do
      String.starts_with?(pattern, "def ") ->
        case String.split(pattern, "(", parts: 2) do
          [prefix, _] -> prefix <> "("
          _ -> pattern
        end

      String.contains?(pattern, ".") and String.contains?(pattern, "(") ->
        case String.split(pattern, "(", parts: 2) do
          [prefix, _] ->
            func = prefix |> String.split(".") |> List.last()
            func <> "("

          _ ->
            pattern
        end

      true ->
        pattern
    end
  end

  @doc """
  Scan target files for a broader pattern and return sample matches for diagnostics.
  """
  @spec diagnose(String.t(), [String.t()], (String.t() -> String.t()), map()) :: String.t()
  def diagnose(broad_pattern, file_list, resolve_fn, staging_buffer) do
    samples =
      file_list
      |> Enum.flat_map(fn file_path ->
        resolved = resolve_fn.(file_path)

        content =
          case Map.get(staging_buffer, resolved) do
            nil ->
              case File.read(resolved) do
                {:ok, c} -> c
                _ -> nil
              end

            staged ->
              staged
          end

        if is_binary(content) do
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.contains?(line, broad_pattern)
          end)
          |> Enum.map(fn {line, num} ->
            "  #{Path.basename(file_path)}:#{num}: #{String.trim(line)}"
          end)
        else
          []
        end
      end)
      |> Enum.take(10)

    if samples != [] do
      """

      DIAGNOSTIC: Your exact pattern was not found. Searching for '#{broad_pattern}' instead, I found these actual lines:
      #{Enum.join(samples, "\n")}

      Use one of these exact strings as your pattern instead.
      """
    else
      "\nDIAGNOSTIC: No similar patterns found with '#{broad_pattern}' either. The files may not contain what you expect.\n"
    end
  end
end
