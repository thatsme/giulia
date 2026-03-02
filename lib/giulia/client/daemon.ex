defmodule Giulia.Client.Daemon do
  @moduledoc """
  Docker daemon lifecycle — start, stop, health checks.
  """

  alias Giulia.Client.HTTP
  alias Giulia.Client.Output

  @docker_image "giulia/core:latest"

  def ensure_running do
    if healthy?() do
      :ok
    else
      if docker_running?() do
        # Container exists but API not responding - wait a bit
        Process.sleep(2000)
        if healthy?(), do: :ok, else: {:error, :daemon_not_healthy}
      else
        start_docker()
      end
    end
  end

  def healthy? do
    case HTTP.get("/health") do
      {:ok, %{"status" => "ok"}} -> true
      _ -> false
    end
  end

  def stop do
    System.cmd("docker", ["stop", "giulia-daemon"], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "giulia-daemon"], stderr_to_stdout: true)
    :ok
  end

  defp docker_running? do
    case System.cmd("docker", ["ps", "-q", "-f", "name=giulia-daemon"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp start_docker do
    Output.info("Starting Giulia daemon container...")

    projects_path = System.get_env("GIULIA_PROJECTS_PATH", default_projects_path())

    args = [
      "run", "-d",
      "--name", "giulia-daemon",
      "--hostname", "giulia-daemon",
      "-v", "giulia_data:/data",
      "-v", "#{projects_path}:/projects",
      "-p", "4000:4000",
      @docker_image
    ]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_, 0} ->
        wait_for_daemon()

      {error, _} ->
        {:error, error}
    end
  end

  defp wait_for_daemon, do: wait_for_daemon(30)

  defp wait_for_daemon(0), do: {:error, :timeout}
  defp wait_for_daemon(attempts) do
    Process.sleep(1000)
    if healthy?() do
      Output.info("Daemon started.")
      :ok
    else
      wait_for_daemon(attempts - 1)
    end
  end

  defp default_projects_path do
    Giulia.Client.get_working_directory() |> Path.dirname()
  end
end
