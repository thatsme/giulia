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

  # Tool behavior that all tools must implement
  # Note: execute/1 is expected but not a required callback since tools
  # may have multiple overloaded clauses with different types
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Register a tool module.
  """
  def register(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end

  @doc """
  Get all registered tools as a list for the LLM.
  """
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Get a tool by name.
  """
  def get_tool(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Execute a tool by name with arguments.
  Returns {:ok, result} or {:error, reason}.

  Accepts optional opts for sandbox and project_path.
  """
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
  def list_tool_names do
    GenServer.call(__MODULE__, :list_tool_names)
  end

  @doc """
  Auto-discover and register all tools in the tools directory.
  """
  def discover_tools do
    GenServer.cast(__MODULE__, :discover_tools)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Auto-discover on startup
    do_discover_tools()

    {:ok, %{}}
  end

  @impl true
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
      Giulia.Tools.WriteFunction,    # AST-based function replacement (legacy)
      Giulia.Tools.PatchFunction,    # Sourceror-based patching (preferred for code tools)
      Giulia.Tools.ListFiles,

      # Code intelligence (AST-powered)
      Giulia.Tools.LookupFunction,   # Index-based lookup (preferred for known functions)
      Giulia.Tools.GetFunction,      # The Slicer - requires file path
      Giulia.Tools.GetModuleInfo,    # From ETS, no file reading
      Giulia.Tools.GetContext,       # Context around errors
      Giulia.Tools.SearchCode,       # Grep-like search

      # Build/Test
      Giulia.Tools.RunMix,           # Safe mix commands only
      Giulia.Tools.CycleCheck,       # Detect compile-time cyclic dependencies

      # Pseudo-tools for orchestration
      Giulia.Tools.Respond,
      Giulia.Tools.Think
    ]

    Enum.each(known_tools, &do_register/1)
  end
end
