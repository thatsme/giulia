defmodule Giulia.Fixtures.FrameworkCallbacks do
  @moduledoc """
  GenServer-style module exercising common framework wiring that
  extraction must see: `use GenServer`, `@impl true`, callback
  functions (`init/1`, `handle_call/3`, `handle_cast/2`,
  `terminate/2`), plus `@behaviour` + `@callback` declarations.

  Historical regressions in this area: callbacks missed entirely
  because the extraction walked only top-level `def`; `@impl true`
  on a `def` was sometimes attributed to the wrong function when
  sibling attributes were reordered.
  """

  use GenServer

  @behaviour Giulia.Fixtures.SomeBehaviour

  @callback custom_hook(any()) :: :ok | {:error, term()}
  @optional_callbacks custom_hook: 1

  defstruct [:counter, :name]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{counter: 0, name: "demo"}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.counter, state}
  end

  def handle_call({:set, n}, _from, state) when is_integer(n) do
    {:reply, :ok, %{state | counter: n}}
  end

  @impl true
  def handle_cast(:increment, state) do
    {:noreply, %{state | counter: state.counter + 1}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Not a callback — a plain public function. Extraction should not
  # label it as a callback even if it's in a module with `use GenServer`.
  def plain_helper(x), do: x * 2
end
