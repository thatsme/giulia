defmodule Giulia.Version do
  @moduledoc """
  Version tracking for both client and server.

  Build number is compiled into the binary - if you see different
  builds between client and server, something wasn't rebuilt.
  """

  # These are compile-time constants
  @version Mix.Project.config()[:version]
  @build Mix.Project.config()[:build] || 0

  @spec version() :: String.t()
  def version, do: @version

  @spec build() :: non_neg_integer()
  def build, do: @build

  @spec short_version() :: String.t()
  def short_version do
    "v#{@version}.#{@build}"
  end
end
