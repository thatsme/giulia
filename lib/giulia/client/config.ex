defmodule Giulia.Client.Config do
  @moduledoc """
  Shared client configuration — working directory, env vars.
  Zero dependencies on other Client modules (cycle-breaker).
  """

  @doc "Get the real working directory (where user launched from)."
  @spec working_directory() :: String.t()
  def working_directory do
    case System.get_env("GIULIA_CLIENT_CWD") do
      nil -> File.cwd!()
      "" -> File.cwd!()
      dir -> dir
    end
  end
end
