defmodule Giulia do
  @moduledoc """
  Giulia - A high-performance, local-first AI development agent built in Elixir.

  Architecture: Daemon-Client Model

  Giulia runs as a persistent background daemon with multi-project awareness.
  The CLI is a thin client that connects to the daemon.

  Core features:
  - OTP supervision tree for state management
  - Native AST integration for code analysis (Sourceror)
  - Provider-agnostic LLM support (Anthropic, Ollama, LM Studio)
  - Structured tool calls via Ecto schemas
  - Path sandbox for security
  - Multi-project awareness via ProjectContext
  """

  alias Giulia.Context.{Store, Indexer}
  alias Giulia.Agent.Orchestrator

  @doc """
  Initialize Giulia with a project path.
  This is the legacy direct API - for daemon mode, use Giulia.Daemon.init_project/2.
  """
  def init(project_path) do
    Indexer.scan(project_path)
    Store.put(:project_path, project_path)
    :ok
  end

  @doc """
  Run a task through the agent orchestrator.
  This is the legacy direct API - for daemon mode, use Giulia.Daemon.chat/2.
  """
  def run(task, opts \\ []) do
    Orchestrator.run(task, opts)
  end

  @doc """
  Get the current project state.
  """
  def status do
    %{
      indexer: Indexer.status(),
      store: Store.stats(),
      provider: Giulia.Provider.current()
    }
  end

  @doc """
  Switch the active provider.
  """
  def use_provider(provider) when provider in [:anthropic, :ollama, :lm_studio] do
    module =
      case provider do
        :anthropic -> Giulia.Provider.Anthropic
        :ollama -> Giulia.Provider.Ollama
        :lm_studio -> Giulia.Provider.LMStudio
      end

    Application.put_env(:giulia, :provider, module)
    :ok
  end

  @doc """
  Get the version of Giulia.
  """
  def version do
    Application.spec(:giulia, :vsn) |> to_string()
  end
end
