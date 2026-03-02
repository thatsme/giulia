defmodule Giulia.Client.REPL do
  @moduledoc """
  Interactive REPL — multiline input, history, command dispatch.
  """

  alias Giulia.Client
  alias Giulia.Client.{Commands, Output, HTTP, Renderer}

  @heredoc_delim ~s(""")

  def start do
    Output.print_banner()
    host_path = Client.get_working_directory()

    # Check if project is initialized (lightweight ping - no inference)
    case HTTP.post("/api/ping", %{path: host_path}) do
      {:ok, %{"status" => "needs_init"}} ->
        Output.warning("No GIULIA.md found.")

        if Output.confirm?("Initialize Giulia in current directory?") do
          Client.init_project(host_path)
          Output.success("Initialized!")
        end

      _ ->
        :ok
    end

    repl_loop(host_path)
  end

  defp repl_loop(host_path), do: repl_loop(host_path, [])

  defp repl_loop(host_path, history) do
    case read_full_input() do
      :eof ->
        Output.info("\nGoodbye!")

      line ->
        cond do
          line == "" ->
            repl_loop(host_path, history)

          line in ["/quit", "/exit", "/q"] ->
            Output.info("Goodbye!")

          line == "/history" ->
            print_history(history)
            repl_loop(host_path, history)

          Regex.match?(~r/^!(\d+)$/, line) ->
            [_, num_str] = Regex.run(~r/^!(\d+)$/, line)
            num = String.to_integer(num_str)
            case Enum.at(history, num - 1) do
              nil ->
                Output.warning("No command ##{num} in history")
                repl_loop(host_path, history)
              cmd ->
                Output.info("Replaying: #{cmd}")
                history = [cmd | history] |> Enum.take(100)
                execute_or_command(cmd, host_path)
                repl_loop(host_path, history)
            end

          line == "!!" ->
            case List.first(history) do
              nil ->
                Output.warning("No previous command")
                repl_loop(host_path, history)
              cmd ->
                Output.info("Replaying: #{cmd}")
                execute_or_command(cmd, host_path)
                repl_loop(host_path, history)
            end

          String.starts_with?(line, "/") ->
            history = [line | history] |> Enum.take(100)
            args = String.split(line)
            Commands.process(args)
            repl_loop(host_path, history)

          true ->
            history = [line | history] |> Enum.take(100)
            Renderer.execute_input(line, host_path)
            repl_loop(host_path, history)
        end
    end
  end

  # Read a full input line, handling multiline modes
  defp read_full_input do
    case IO.gets("giulia> ") do
      :eof ->
        :eof

      raw ->
        line = raw |> to_string() |> strip_newline()
        trimmed = String.trim(line)

        cond do
          trimmed == @heredoc_delim ->
            IO.puts("\e[90m  (multiline mode — close with \"\"\" on its own line)\e[0m")
            read_heredoc([])

          String.starts_with?(trimmed, @heredoc_delim) ->
            after_open = String.replace_prefix(trimmed, @heredoc_delim, "")
            if String.length(after_open) >= 3 and String.ends_with?(after_open, @heredoc_delim) do
              after_open |> String.replace_suffix(@heredoc_delim, "") |> String.trim()
            else
              read_heredoc([after_open])
            end

          String.ends_with?(trimmed, "\\") ->
            first = String.slice(trimmed, 0, String.length(trimmed) - 1) |> String.trim_trailing()
            read_continuation([first])

          true ->
            trimmed
        end
    end
  end

  defp strip_newline(s), do: s |> String.trim_trailing("\n") |> String.trim_trailing("\r")

  defp read_heredoc(acc) do
    case IO.gets("...  ") do
      :eof ->
        acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

      raw ->
        line = raw |> to_string() |> strip_newline()
        trimmed = String.trim(line)

        cond do
          trimmed == @heredoc_delim ->
            acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

          String.ends_with?(trimmed, @heredoc_delim) ->
            last_part = String.replace_suffix(trimmed, @heredoc_delim, "")
            [last_part | acc] |> Enum.reverse() |> Enum.join("\n") |> String.trim()

          true ->
            read_heredoc([line | acc])
        end
    end
  end

  defp read_continuation(acc) do
    case IO.gets("...  ") do
      :eof ->
        acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()

      raw ->
        line = raw |> to_string() |> strip_newline() |> String.trim()

        if String.ends_with?(line, "\\") do
          part = String.slice(line, 0, String.length(line) - 1) |> String.trim_trailing()
          read_continuation([part | acc])
        else
          [line | acc] |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        end
    end
  end

  defp execute_or_command(cmd, host_path) do
    if String.starts_with?(cmd, "/") do
      args = String.split(cmd)
      Commands.process(args)
    else
      Renderer.execute_input(cmd, host_path)
    end
  end

  defp print_history([]) do
    Output.info("No history yet.")
  end

  defp print_history(history) do
    IO.puts("\n  \e[36mHistory:\e[0m")
    history
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.each(fn {cmd, idx} ->
      display = if String.length(cmd) > 60, do: String.slice(cmd, 0, 57) <> "...", else: cmd
      IO.puts("  \e[33m#{String.pad_leading(Integer.to_string(idx), 3)}\e[0m  #{display}")
    end)
    IO.puts("")
    Output.info("Use !N to replay command #N, or !! to replay last command")
  end
end
