defmodule Giulia.Inference.Supervisor do
  @moduledoc """
  Supervisor for the inference subsystem.

  Starts and manages:
  - Inference pools (one per provider type)

  Each pool ensures back-pressure: only one inference at a time per provider.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Pool for local 3B model (LM Studio)
      {Giulia.Inference.Pool, :local_3b},

      # Pool for local 32B model (Ollama)
      {Giulia.Inference.Pool, :local_32b},

      # Pool for cloud (Anthropic)
      {Giulia.Inference.Pool, :cloud_sonnet}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
