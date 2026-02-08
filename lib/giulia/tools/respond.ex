defmodule Giulia.Tools.Respond do
  @moduledoc """
  Pseudo-tool for the model to signal task completion.

  When the model returns {"tool": "respond", "parameters": {"message": "..."}},
  the Orchestrator knows to stop the thinking loop and return the message.

  This is NOT a real tool - the Orchestrator intercepts it.
  """

  @behaviour Giulia.Tools.Registry

  @impl true
  def name, do: "respond"

  @impl true
  def description, do: "Send a final response to the user (ends the thinking loop)"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        message: %{
          type: "string",
          description: "The message to send to the user"
        }
      },
      required: ["message"]
    }
  end

  # This should never be called - Orchestrator intercepts
  @impl true
  def execute(%{"message" => message}, _opts), do: {:ok, message}
  def execute(_, _opts), do: {:error, :invalid_parameters}
end
