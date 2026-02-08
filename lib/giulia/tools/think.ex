defmodule Giulia.Tools.Think do
  @moduledoc """
  Pseudo-tool for the model to express reasoning.

  When the model returns {"tool": "think", "parameters": {"thought": "..."}},
  the Orchestrator logs the thought and continues the loop.

  This helps small models (3B) by giving them a way to "show their work"
  before taking action. It improves accuracy on multi-step tasks.
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "think"

  @impl true
  def description, do: "Express your reasoning before taking action (continues the loop)"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        thought: %{
          type: "string",
          description: "Your reasoning or analysis"
        }
      },
      required: ["thought"]
    }
  end

  # This should never be called - Orchestrator handles it
  @impl true
  def execute(%{"thought" => thought}, _opts), do: {:ok, "Thought recorded: #{thought}"}
  def execute(_, _opts), do: {:error, :invalid_parameters}
end
