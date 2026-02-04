defmodule Giulia.Version do
  @moduledoc """
  Version tracking for both client and server.

  Build number is compiled into the binary - if you see different
  builds between client and server, something wasn't rebuilt.
  """

  # These are compile-time constants
  @version Mix.Project.config()[:version]
  @build_time DateTime.utc_now() |> DateTime.to_iso8601()

  def version, do: @version
  def build_time, do: @build_time

  def full_version do
    "v#{@version} (built #{@build_time})"
  end

  def short_version do
    # Extract just time portion for display
    time = @build_time |> String.split("T") |> List.last() |> String.slice(0, 8)
    "v#{@version}@#{time}"
  end
end
