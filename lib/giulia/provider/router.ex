defmodule Giulia.Provider.Router do
  @moduledoc """
  The Traffic Controller - Routes tasks to the right model.

  The insight: A 3B model can do real work if fed the right slices.
  A 70B model is overkill for "what does this function do?"

  Classification:
  - :elixir_native  -> Handle in pure Elixir (no LLM needed)
  - :local_3b       -> LM Studio with Qwen 2.5 Coder 3B (micro-tasks)
  - :local_32b      -> Ollama with larger model (home mode)
  - :cloud_sonnet   -> Claude Sonnet (heavy lifting)
  """

  require Logger

  @type provider :: :elixir_native | :local_3b | :local_32b | :cloud_sonnet
  @type classification :: %{
          provider: provider(),
          reason: String.t(),
          intensity: :none | :low | :medium | :high
        }

  # Keywords that indicate complexity
  @high_intensity_keywords ~w(
    refactor architect redesign restructure migrate
    rewrite optimize debug trace investigate
    implement feature add functionality create module
    fix bug resolve issue
  )

  @low_intensity_keywords ~w(
    explain describe what how summarize
    docstring format rename suggest
    check typo lint validate
  )

  @meta_keywords ~w(
    status modules functions projects index
    list show help quit exit stop
  )

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Classify a task and return the recommended provider.

  ## Examples

      iex> Router.route("What modules are in this project?", %{})
      %{provider: :elixir_native, reason: "Meta query - handled by ETS", intensity: :none}

      iex> Router.route("Explain the init function", %{file_count: 5})
      %{provider: :local_3b, reason: "Simple explanation - 3B model sufficient", intensity: :low}

      iex> Router.route("Refactor the authentication system", %{})
      %{provider: :cloud_sonnet, reason: "Complex refactoring - needs full context", intensity: :high}
  """
  @spec route(String.t(), map()) :: classification()
  def route(prompt, context_metadata \\ %{}) do
    prompt_lower = String.downcase(prompt)

    cond do
      meta_command?(prompt_lower) ->
        %{
          provider: :elixir_native,
          reason: "Meta query - handled in pure Elixir",
          intensity: :none
        }

      simple_task?(prompt_lower, context_metadata) ->
        %{
          provider: :local_3b,
          reason: "Simple task - 3B model sufficient",
          intensity: :low
        }

      complex_refactor?(prompt_lower, context_metadata) ->
        %{
          provider: :cloud_sonnet,
          reason: "Complex task - needs full reasoning capability",
          intensity: :high
        }

      medium_task?(prompt_lower, context_metadata) ->
        # Check if we're at home (Ollama available) or work (LM Studio only)
        if ollama_available?() do
          %{
            provider: :local_32b,
            reason: "Medium task - local 32B model",
            intensity: :medium
          }
        else
          # Fall back to cloud if no large local model
          %{
            provider: :cloud_sonnet,
            reason: "Medium task - no local 32B, using cloud",
            intensity: :medium
          }
        end

      true ->
        # Default: try local 3B first, it's fast and cheap
        %{
          provider: :local_3b,
          reason: "Default routing - trying fast local first",
          intensity: :low
        }
    end
  end

  @doc """
  Get the provider module for a classification.
  """
  @spec get_provider_module(provider()) :: module() | :native
  def get_provider_module(:elixir_native), do: :native
  def get_provider_module(:local_3b), do: Giulia.Provider.LMStudio
  def get_provider_module(:local_32b), do: Giulia.Provider.Ollama
  def get_provider_module(:cloud_sonnet), do: Giulia.Provider.Anthropic

  @doc """
  Check if a provider is available (model running, API key present, etc.)
  """
  @spec provider_available?(provider()) :: boolean()
  def provider_available?(:elixir_native), do: true

  def provider_available?(:local_3b) do
    # Check if LM Studio is responding (Docker-aware)
    # No retries - fail fast if not available
    url = lm_studio_health_url()
    case Req.get(url, receive_timeout: 2000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp lm_studio_health_url do
    # Use PathMapper's lm_studio_url but point to /models for health check
    base = Giulia.Core.PathMapper.lm_studio_url()
    String.replace(base, "/chat/completions", "/models")
  end

  def provider_available?(:local_32b), do: ollama_available?()

  def provider_available?(:cloud_sonnet) do
    # Check if API key is configured
    api_key = Application.get_env(:giulia, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")
    api_key != nil and api_key != ""
  end

  @doc """
  Get fallback provider if primary is unavailable.
  """
  @spec fallback(provider()) :: provider() | nil
  def fallback(:local_3b), do: :cloud_sonnet
  def fallback(:local_32b), do: :cloud_sonnet
  def fallback(:cloud_sonnet), do: :local_3b
  def fallback(:elixir_native), do: nil

  # ============================================================================
  # Classification Logic
  # ============================================================================

  # Helper: Clean keyword matching
  defp has_any?(prompt, keywords) do
    Enum.any?(keywords, &String.contains?(prompt, &1))
  end

  defp meta_command?(prompt) do
    # Slash commands are always native
    if String.starts_with?(prompt, "/") do
      true
    else
      # PRIORITY: Action verbs ALWAYS win over nouns
      # "optimize the module" -> LLM (optimize is action)
      # "list modules" -> native (list is meta, no action)
      has_action = has_any?(prompt, @high_intensity_keywords)
      has_meta = has_any?(prompt, @meta_keywords)
      has_question = String.contains?(prompt, "how") or String.contains?(prompt, "why")

      # Only route to native if meta-only, no action verbs, no questions
      has_meta and not has_action and not has_question
    end
  end

  defp simple_task?(prompt, _context) do
    # Low intensity: explanation, formatting, docstrings
    # BUT action verbs always escalate
    has_low = has_any?(prompt, @low_intensity_keywords)
    has_action = has_any?(prompt, @high_intensity_keywords)
    short_prompt = String.length(prompt) < 100

    has_low and not has_action and short_prompt
  end

  defp complex_refactor?(prompt, context) do
    # High intensity: any action verb triggers this
    has_action = has_any?(prompt, @high_intensity_keywords)

    # Multi-file operations also escalate
    mentions_multiple = String.contains?(prompt, "all") or
                        String.contains?(prompt, "every") or
                        String.contains?(prompt, "across")

    large_context = Map.get(context, :file_count, 0) > 20

    has_action or (mentions_multiple and large_context)
  end

  defp medium_task?(prompt, context) do
    # Everything that isn't clearly simple or complex
    not simple_task?(prompt, context) and not complex_refactor?(prompt, context)
  end

  defp ollama_available? do
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 2000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
