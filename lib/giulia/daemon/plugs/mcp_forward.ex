defmodule Giulia.Daemon.Plugs.McpForward do
  @moduledoc """
  Runtime forwarder to the Anubis MCP StreamableHTTP Plug.

  Chains Bearer token authentication via McpAuth, then defers
  `Anubis.Server.Transport.StreamableHTTP.Plug.init/1` until the first
  request. This avoids the persistent_term race where Anubis.Server.Supervisor
  hasn't stored the session config yet at Plug.Router compile time.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Giulia.Daemon.Plugs.McpAuth.call(conn, []) do
      %{halted: true} = conn ->
        conn

      conn ->
        plug_opts = Anubis.Server.Transport.StreamableHTTP.Plug.init(server: Giulia.MCP.Server)
        Anubis.Server.Transport.StreamableHTTP.Plug.call(conn, plug_opts)
    end
  end
end
