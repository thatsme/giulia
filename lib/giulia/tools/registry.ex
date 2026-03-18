defmodule Giulia.Tools.Registry do
  @moduledoc """
  Tool Discovery via Elixir Registry.

  When Giulia boots, every tool registers itself.
  The Orchestrator gathers these registrations and builds the "Menu" for the LLM.

  When you add a new .ex file to tools/, Giulia's brain automatically
  learns that capability on the next turn. Plug-and-play intelligence.
  """
  use GenServer

  @table __MODULE__

  @type tool_spec :: %{module: module(), name: String.t(), description: String.t(), parameters: map()}

  # Tool behavior that all tools must implement
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Register a tool module.
  """
  @spec register(module()) :: {:ok, String.t()} | {:error, {:registration_failed, module(), term()}}
  def register(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end

  @doc """
  Get all registered tools as a list for the LLM.
  """
  @spec list_tools() :: [tool_spec()]
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Get a tool by name.
  """
  @spec get_tool(String.t()) :: {:ok, module()} | :not_found
  def get_tool(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Execute a tool by name with arguments.
  Returns {:ok, result} or {:error, reason}.

  Accepts optional opts for sandbox and project_path.
  """
  @spec execute(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(name, arguments, opts \\ []) do
    case get_tool(name) do
      {:ok, module} ->
        module.execute(arguments, opts)

      :not_found ->
        {:error, {:unknown_tool, name, list_tool_names()}}
    end
  end

  @doc """
  Get just the tool names (for error messages).
  """
  @spec list_tool_names() :: [String.t()]
  def list_tool_names do
    GenServer.call(__MODULE__, :list_tool_names)
  end

  @doc """
  Auto-discover and register all tools in the tools directory.
  """
  @spec discover_tools() :: :ok
  def discover_tools do
    GenServer.cast(__MODULE__, :discover_tools)
  end

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Auto-discover on startup
    do_discover_tools()

    {:ok, %{}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call({:register, module}, _from, state) do
    result = do_register(module)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools =
      :ets.tab2list(@table)
      |> Enum.map(fn {_name, tool_spec} -> tool_spec end)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    result =
      case :ets.lookup(@table, name) do
        [{^name, %{module: module}}] -> {:ok, module}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tool_names, _from, state) do
    names =
      :ets.tab2list(@table)
      |> Enum.map(fn {name, _} -> name end)

    {:reply, names, state}
  end

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast(:discover_tools, state) do
    do_discover_tools()
    {:noreply, state}
  end

  # Private

  defp do_register(module) do
    try do
      tool_spec = %{
        module: module,
        name: module.name(),
        description: module.description(),
        parameters: module.parameters()
      }

      :ets.insert(@table, {tool_spec.name, tool_spec})
      {:ok, tool_spec.name}
    rescue
      e -> {:error, {:registration_failed, module, e}}
    end
  end

  defp do_discover_tools do
    # Register known tools
    known_tools = [
      # File operations
      Giulia.Tools.ReadFile,
      Giulia.Tools.WriteFile,
      Giulia.Tools.EditFile,
      # AST-based function replacement (legacy)
      Giulia.Tools.WriteFunction,
      # Sourceror-based patching (preferred for code tools)
      Giulia.Tools.PatchFunction,
      Giulia.Tools.ListFiles,

      # Code intelligence (AST-powered)
      # Index-based lookup (preferred for known functions)
      Giulia.Tools.LookupFunction,
      # The Slicer - requires file path
      Giulia.Tools.GetFunction,
      # From ETS, no file reading
      Giulia.Tools.GetModuleInfo,
      # Context around errors
      Giulia.Tools.GetContext,
      # Grep-like search
      Giulia.Tools.SearchCode,

      # Build/Test
      # Safe mix commands only
      Giulia.Tools.RunMix,
      # Structured ExUnit test runner
      Giulia.Tools.RunTests,
      # Detect compile-time cyclic dependencies
      Giulia.Tools.CycleCheck,

      # Knowledge graph
      Giulia.Tools.GetImpactMap,
      Giulia.Tools.TracePath,

      # Semantic search (requires embedding model)
      Giulia.Tools.SearchMeaning,

      # Pseudo-tools for orchestration
      Giulia.Tools.Respond,
      Giulia.Tools.Think,
      Giulia.Tools.CommitChanges,
      Giulia.Tools.GetStagedFiles,
      Giulia.Tools.BulkReplace,
      Giulia.Tools.RenameMFA
    ]

    Enum.each(known_tools, &do_register/1)
  end
end
