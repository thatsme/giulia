defmodule Giulia.Application do
  @moduledoc """
  Giulia OTP Application.

  Architecture: Daemon-Client Model

  When started normally (via mix or iex):
  - Core services start (Registry, Tools, Providers)
  - Context services are lazy (started when daemon runs)

  When started as daemon:
  - Full supervision tree including ProjectContexts
  - Persistent across terminal sessions

  Supervision tree:
  - Registry for named process lookup
  - Context.Store (ETS) for codebase state
  - Tools.Registry for auto-discovered tools
  - Context.Indexer for background AST scanning
  - Provider.Supervisor for API/Local connections
  - Agent.Supervisor for task-specific agents

  Daemon-specific (started by Giulia.Daemon.start/0):
  - Core.ProjectSupervisor for per-project contexts
  - Core.ContextManager for routing requests
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Check if running as thin client (escript) - don't start daemon services
    # The client only needs Req HTTP client, no supervision tree
    if client_mode?() do
      # Empty supervision tree - client just makes HTTP calls
      Supervisor.start_link([], strategy: :one_for_one, name: Giulia.Supervisor)
    else
      start_daemon_mode()
    end
  end

  # Detect if we're running as the thin client (escript)
  # Client mode = NOT in container AND NOT explicitly running as daemon
  defp client_mode? do
    explicit_client = System.get_env("GIULIA_CLIENT_MODE") == "true"
    explicit_daemon = System.get_env("GIULIA_DAEMON_MODE") == "true"
    in_container = System.get_env("GIULIA_IN_CONTAINER") == "true"

    cond do
      explicit_client -> true
      explicit_daemon -> false
      # Container = daemon mode
      in_container -> false
      # Default outside container = client mode
      true -> true
    end
  end

  defp start_daemon_mode do
    port =
      case Integer.parse(System.get_env("GIULIA_PORT", "4000")) do
        {n, _} -> n
        :error -> 4000
      end

    role = Giulia.Role.role()

    base_children = [
      # Registry for named process lookup
      {Registry, keys: :unique, name: Giulia.Registry},

      # ETS-backed context store for project state
      Giulia.Context.Store,

      # Persistent key-value store (CubDB lifecycle per project)
      Giulia.Persistence.Store,

      # Async write-behind for CubDB (100ms debounce batching)
      Giulia.Persistence.Writer,

      # Tool registry (auto-discovers tools on boot)
      Giulia.Tools.Registry,

      # Background AST indexer
      Giulia.Context.Indexer,

      # Knowledge graph (depends on Store + Indexer)
      Giulia.Knowledge.Store,

      # ArcadeDB L2: Indexer (listens for {:graph_ready} from Knowledge.Store)
      Giulia.Storage.Arcade.Indexer,

      # ArcadeDB consolidation (periodic cross-build analysis)
      Giulia.Storage.Arcade.Consolidator
    ]

    # Heavy children — skipped in monitor mode to save ~200MB RAM
    # (EmbeddingServing loads a ~90MB transformer model the monitor never uses)
    heavy_children =
      if role == :monitor do
        []
      else
        [
          # Embedding model serving (optional — returns :ignore if model fails to load)
          Giulia.Intelligence.EmbeddingServing,

          # Semantic search index (depends on Store + EmbeddingServing)
          Giulia.Intelligence.SemanticIndex
        ]
      end

    inference_children =
      if role == :monitor do
        []
      else
        [
          # Dynamic supervisor for provider connections
          {DynamicSupervisor, strategy: :one_for_one, name: Giulia.Provider.Supervisor},

          # Trace storage for debugging inference runs
          Giulia.Inference.Trace,

          # Event broadcaster for SSE streaming
          Giulia.Inference.Events,

          # Approval manager for interactive consent gate
          Giulia.Inference.Approval,

          # Inference subsystem (pools with back-pressure)
          Giulia.Inference.Supervisor
        ]
      end

    tail_children = [
      # Logic Monitor event buffer (Build 95)
      Giulia.Monitor.Store,

      # Dynamic supervisor for per-project contexts
      {DynamicSupervisor, strategy: :one_for_one, name: Giulia.Core.ProjectSupervisor},

      # Context manager - routes requests to correct ProjectContext
      Giulia.Core.ContextManager,

      # Runtime collector (periodic BEAM health snapshots)
      Giulia.Runtime.Collector,

      # Ingest store for Monitor→Worker snapshot pipeline (Build 133)
      Giulia.Runtime.IngestStore,

      # Observation controller for async start/stop observation (Build 133)
      Giulia.Runtime.Observer,

      # Auto-connect to target node (returns :ignore if GIULIA_CONNECT_NODE unset)
      {Giulia.Runtime.AutoConnect, []},

      # Monitor lifecycle orchestrator (returns :ignore unless GIULIA_ROLE=monitor)
      {Giulia.Runtime.Monitor, []}
    ]

    all_children = base_children ++ heavy_children ++ inference_children ++ tail_children

    # Skip HTTP endpoint in test env (port already in use by the running daemon)
    children =
      if Mix.env() == :test do
        all_children
      else
        all_children ++ [{Bandit, plug: Giulia.Daemon.Endpoint, port: port}]
      end

    opts = [strategy: :one_for_one, name: Giulia.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Attach telemetry handlers after supervisor is up (Build 95)
    case result do
      {:ok, _pid} -> Giulia.Monitor.Telemetry.attach()
      _ -> :ok
    end

    result
  end
end
