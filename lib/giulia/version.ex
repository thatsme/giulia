defmodule Giulia.Version do
  @moduledoc """
  Version tracking for both client and server.

  Build number is compiled into the binary - if you see different
  builds between client and server, something wasn't rebuilt.
  """

  # These are compile-time constants
  @version Mix.Project.config()[:version]
  @build Mix.Project.config()[:build] || 0

  def version, do: @version
  def build, do: @build

  def short_version do
    "v#{@version}.#{@build}"
  end
end
