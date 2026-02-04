defmodule Giulia.Daemon do
  @moduledoc """
  The Persistent Background Daemon.

  This is the "always-on" BEAM node that:
  - Keeps the local LLM warm (no cold starts)
  - Maintains AST indices across sessions
  - Manages multiple ProjectContexts simultaneously
  - Serves client connections from any directory

  Architecture:
  - Runs as a distributed Erlang node: giulia@localhost
  - Clients connect via :rpc or a simple TCP protocol
  - State persists across terminal sessions

  The Philosophy: Start once, run forever, know everything.
  """

  use GenServer

  require Logger

  @node_name :giulia
  @cookie :giulia_secret
  @default_port 9876
  @home_dir Path.expand("~/.config/giulia")

  defstruct [
    :started_at,
    :port,
    :listener_pid,
    clients: %{},
    stats: %{
      connections: 0,
      requests: 0,
      uptime_seconds: 0
    }
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the Giulia daemon.
  Called when `giulia` is run and no daemon is detected.
  """
  def start do
    ensure_home_dir()
    setup_node()

    case start_supervised() do
      {:ok, _pid} ->
        Logger.info("Giulia Daemon started on #{node()}")
        write_pid_file()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if the daemon is running.
  """
  def running? do
    case read_pid_file() do
      {:ok, _pid} ->
        # Try to ping the node
        node_name = :"#{@node_name}@localhost"
        Node.ping(node_name) == :pong

      :error ->
        false
    end
  end

  @doc """
  Connect to the running daemon.
  Returns the daemon node name if successful.
  """
  def connect do
    node_name = :"#{@node_name}@localhost"

    # Start a client node if not already started
    unless Node.alive?() do
      client_name = :"giulia_client_#{:rand.uniform(10000)}@localhost"
      Node.start(client_name, :shortnames)
      Node.set_cookie(@cookie)
    end

    case Node.connect(node_name) do
      true ->
        {:ok, node_name}

      false ->
        {:error, :connection_failed}
    end
  end

  @doc """
  Stop the daemon gracefully.
  """
  def stop do
    GenServer.stop(__MODULE__)
    delete_pid_file()
    :ok
  end

  @doc """
  Get daemon status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Handle a request from a client.
  This is the main entry point for client interactions.
  """
  def handle_request(request, client_pid) do
    GenServer.call(__MODULE__, {:request, request, client_pid}, :infinity)
  end

  # ============================================================================
  # Client-Facing Operations (called via :rpc from clients)
  # ============================================================================

  @doc """
  Process a chat message from a client.
  The client sends: {pwd, message}
  """
  def chat(pwd, message) do
    case Giulia.Core.ContextManager.get_context(pwd) do
      {:ok, context_pid} ->
        # Route to the appropriate ProjectContext
        do_chat(context_pid, message)

      {:needs_init, path} ->
        {:needs_init, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Initialize a project from a client request.
  """
  def init_project(path, opts \\ []) do
    Giulia.Core.ContextManager.init_project(path, opts)
  end

  @doc """
  List all active projects.
  """
  def list_projects do
    Giulia.Core.ContextManager.list_projects()
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    state = %__MODULE__{
      started_at: DateTime.utc_now(),
      port: port
    }

    # Start uptime tracker
    schedule_uptime_tick()

    # Start TCP listener for non-Erlang clients (optional)
    # {:ok, listener_pid} = start_tcp_listener(port)

    Logger.info("Daemon initialized at #{state.started_at}")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      node: node(),
      started_at: state.started_at,
      uptime_seconds: state.stats.uptime_seconds,
      active_projects: length(Giulia.Core.ContextManager.list_projects()),
      total_connections: state.stats.connections,
      total_requests: state.stats.requests
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:request, request, client_pid}, _from, state) do
    # Track the client
    clients = Map.put(state.clients, client_pid, DateTime.utc_now())
    stats = %{state.stats | requests: state.stats.requests + 1}

    result = process_request(request)

    {:reply, result, %{state | clients: clients, stats: stats}}
  end

  @impl true
  def handle_info(:uptime_tick, state) do
    new_stats = %{state.stats | uptime_seconds: state.stats.uptime_seconds + 60}
    schedule_uptime_tick()
    {:noreply, %{state | stats: new_stats}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Client disconnected
    clients = Map.delete(state.clients, pid)
    {:noreply, %{state | clients: clients}}
  end

  # ============================================================================
  # Private - Setup
  # ============================================================================

  defp setup_node do
    node_name = :"#{@node_name}@localhost"

    unless Node.alive?() do
      case Node.start(node_name, :shortnames) do
        {:ok, _} ->
          Node.set_cookie(@cookie)
          Logger.info("Started distributed node: #{node_name}")

        {:error, reason} ->
          Logger.error("Failed to start node: #{inspect(reason)}")
      end
    end
  end

  defp start_supervised do
    # The daemon itself is started under the main application supervisor
    # This function is called when explicitly starting the daemon
    children = [
      # Project supervisor for dynamic ProjectContexts
      {DynamicSupervisor, strategy: :one_for_one, name: Giulia.Core.ProjectSupervisor},

      # Context manager
      Giulia.Core.ContextManager,

      # The daemon GenServer itself
      {__MODULE__, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Giulia.Daemon.Supervisor)
  end

  defp ensure_home_dir do
    File.mkdir_p!(@home_dir)
    File.mkdir_p!(Path.join(@home_dir, "logs"))
    File.mkdir_p!(Path.join(@home_dir, "cache"))
  end

  defp schedule_uptime_tick do
    Process.send_after(self(), :uptime_tick, 60_000)
  end

  # ============================================================================
  # Private - PID File Management
  # ============================================================================

  defp pid_file_path, do: Path.join(@home_dir, "daemon.pid")

  defp write_pid_file do
    pid = System.pid()
    File.write!(pid_file_path(), pid)
  end

  defp read_pid_file do
    case File.read(pid_file_path()) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _} -> :error
    end
  end

  defp delete_pid_file do
    File.rm(pid_file_path())
  end

  # ============================================================================
  # Private - Request Processing
  # ============================================================================

  defp process_request({:chat, pwd, message}) do
    chat(pwd, message)
  end

  defp process_request({:init, path, opts}) do
    init_project(path, opts)
  end

  defp process_request({:list_projects}) do
    list_projects()
  end

  defp process_request({:status}) do
    status()
  end

  defp process_request(unknown) do
    {:error, {:unknown_request, unknown}}
  end

  # ============================================================================
  # Private - Chat Processing
  # ============================================================================

  defp do_chat(context_pid, message) do
    # Get the constitution for this project
    constitution = Giulia.Core.ProjectContext.get_constitution(context_pid)

    # Build the task with constitution context
    task = build_task_with_constitution(message, constitution)

    # Run through the orchestrator
    case Giulia.Agent.Orchestrator.run(task, context_pid: context_pid) do
      {:ok, result} ->
        # Store in history
        Giulia.Core.ProjectContext.add_to_history(context_pid, "user", message)
        Giulia.Core.ProjectContext.add_to_history(context_pid, "assistant", result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_task_with_constitution(message, constitution) do
    taboos =
      if constitution.taboos != [] do
        "\n\nCONSTITUTIONAL TABOOS (never do these):\n" <>
          Enum.map_join(constitution.taboos, "\n", &"- #{&1}")
      else
        ""
      end

    patterns =
      if constitution.patterns != [] do
        "\n\nPREFERRED PATTERNS:\n" <>
          Enum.map_join(constitution.patterns, "\n", &"- #{&1}")
      else
        ""
      end

    message <> taboos <> patterns
  end
end
