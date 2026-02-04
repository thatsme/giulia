defmodule Giulia.Provider do
  @moduledoc """
  Behavior for LLM providers.

  Implementations must handle chat completions with tool support.
  Provider is selected via config - Anthropic for work, Ollama for home.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}
  @type tool_call :: %{name: String.t(), arguments: map()}
  @type response :: %{
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          stop_reason: atom()
        }

  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @callback chat(messages :: [message()], tools :: [tool()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @callback stream(messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Get the currently configured provider module.
  """
  def current do
    Application.get_env(:giulia, :provider, Giulia.Provider.Anthropic)
  end

  @doc """
  Send a chat request to the current provider.
  """
  def chat(messages, opts \\ []) do
    current().chat(messages, opts)
  end

  @doc """
  Send a chat request with tools to the current provider.
  """
  def chat_with_tools(messages, tools, opts \\ []) do
    current().chat(messages, tools, opts)
  end
end
