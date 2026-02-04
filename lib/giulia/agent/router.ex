defmodule Giulia.Agent.Router do
  @moduledoc """
  Task routing logic for provider selection.

  Routes tasks to appropriate providers based on complexity:
  - Low-intensity (Local 3B): Formatting, docstrings, variable names, summaries
  - High-intensity (Cloud): Architecture, debugging, multi-file refactoring

  The "Senior" approach: Don't use a sledgehammer (Claude) to hang a picture frame.
  Use the 3B model to keep Giulia reactive and cheap.
  """

  @type intensity :: :low | :high
  @type task_classification :: %{
          intensity: intensity(),
          provider: module(),
          reason: String.t()
        }

  # Keywords that indicate low-intensity tasks (local 3B)
  @low_intensity_keywords [
    "format",
    "docstring",
    "doc",
    "comment",
    "variable name",
    "rename",
    "summarize",
    "summary",
    "explain",
    "what does",
    "what is",
    "find where",
    "locate",
    "simple",
    "quick",
    "typo",
    "spelling"
  ]

  # Keywords that indicate high-intensity tasks (cloud)
  @high_intensity_keywords [
    "refactor",
    "debug",
    "race condition",
    "architecture",
    "design",
    "implement",
    "build",
    "create",
    "complex",
    "multi-file",
    "entire",
    "whole",
    "supervision",
    "genserver",
    "concurrent",
    "parallel"
  ]

  @doc """
  Classify a task and return the recommended provider.
  """
  @spec classify(String.t()) :: task_classification()
  def classify(task) when is_binary(task) do
    task_lower = String.downcase(task)

    cond do
      # Check high-intensity first (override low if both match)
      has_keywords?(task_lower, @high_intensity_keywords) ->
        %{
          intensity: :high,
          provider: cloud_provider(),
          reason: "Task requires deep reasoning or multi-step planning"
        }

      has_keywords?(task_lower, @low_intensity_keywords) ->
        %{
          intensity: :low,
          provider: local_provider(),
          reason: "Simple task suitable for fast local model"
        }

      # Default based on task length (longer = more complex)
      String.length(task) > 200 ->
        %{
          intensity: :high,
          provider: cloud_provider(),
          reason: "Long task description suggests complexity"
        }

      # Default to local for short, unclassified tasks
      true ->
        %{
          intensity: :low,
          provider: local_provider(),
          reason: "Default to local for quick response"
        }
    end
  end

  @doc """
  Classify based on context size (AST data).
  Large context = needs smarter model.
  """
  @spec classify_by_context(String.t(), map()) :: task_classification()
  def classify_by_context(task, context) do
    base_classification = classify(task)

    # Override to cloud if context is large
    context_size = estimate_context_size(context)

    if context_size > 2000 and base_classification.intensity == :low do
      %{
        intensity: :high,
        provider: cloud_provider(),
        reason: "Large context (#{context_size} tokens) requires smarter model"
      }
    else
      base_classification
    end
  end

  @doc """
  Get the provider for a specific intensity level.
  """
  @spec provider_for(intensity()) :: module()
  def provider_for(:low), do: local_provider()
  def provider_for(:high), do: cloud_provider()

  @doc """
  Check if local provider is available (LM Studio running).
  Falls back to cloud if not.
  """
  @spec ensure_provider_available(task_classification()) :: task_classification()
  def ensure_provider_available(%{provider: Giulia.Provider.LMStudio} = classification) do
    case check_local_availability() do
      :ok ->
        classification

      :unavailable ->
        %{
          classification
          | provider: cloud_provider(),
            reason: classification.reason <> " (local unavailable, using cloud)"
        }
    end
  end

  def ensure_provider_available(classification), do: classification

  @doc """
  Route a task to the appropriate provider and execute.
  """
  @spec route_and_execute(String.t(), list(), keyword()) ::
          {:ok, map(), task_classification()} | {:error, term()}
  def route_and_execute(task, messages, opts \\ []) do
    classification =
      task
      |> classify()
      |> ensure_provider_available()

    provider = classification.provider

    case provider.chat(messages, opts) do
      {:ok, response} -> {:ok, response, classification}
      {:error, _} = error -> error
    end
  end

  # Private

  defp has_keywords?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp cloud_provider do
    Application.get_env(:giulia, :cloud_provider, Giulia.Provider.Anthropic)
  end

  defp local_provider do
    Application.get_env(:giulia, :local_provider, Giulia.Provider.LMStudio)
  end

  defp check_local_availability do
    # Use PathMapper to get the correct URL (Docker-aware)
    url = Giulia.Core.PathMapper.lm_studio_models_url()

    case Req.get(url, receive_timeout: 2000, retry: false) do
      {:ok, %{status: 200}} -> :ok
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp estimate_context_size(context) when is_map(context) do
    context
    |> inspect()
    |> String.length()
    |> div(4)  # Rough token estimate
  end

  defp estimate_context_size(_), do: 0
end
