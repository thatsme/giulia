defmodule Giulia.EtsKeeper do
  @moduledoc """
  Heir process for ETS tables whose owner GenServers can crash.

  When an ETS table owner dies, BEAM normally deletes the table. If the
  table is registered as having an `:heir`, the heir process inherits
  ownership instead, keeping the data alive until the owner is restarted
  by its supervisor and reclaims the table via `claim/1`.

  This module is single-purpose: it does no work, holds no domain state,
  and exists only to hold ETS tables across owner restarts. A crash here
  would itself violate the GIULIA.md "restart-time state recovery"
  invariant — so it is intentionally trivial. The only failure mode it
  can hit is if the supervisor itself decides to restart it, in which
  case the inherited tables die with it. That is acceptable: ETS tables
  in this project carry caches that can be rebuilt from L2 (CubDB) or
  L3 (ArcadeDB), but rebuild is expensive and rare; surviving owner
  crashes is the common case, and that's what this process delivers.

  ## Wiring

  Tables register the keeper as their heir at creation time:

      :ets.new(@table, [
        :named_table, :public, :set,
        read_concurrency: true,
        {:heir, Process.whereis(Giulia.EtsKeeper), :default_gift}
      ])

  After the owner dies, the keeper holds the table. When the owner's
  supervisor restarts it, the new owner's `init/1` calls
  `Giulia.EtsKeeper.claim(@table)`. If the keeper has the table, it
  hands it back via `:ets.give_away/3`; otherwise it returns
  `:no_table` and the new owner creates a fresh table.

  Either way, after `claim/1` returns the new owner re-installs the
  heir option (it does not survive `give_away`), so the next crash is
  also covered.
  """
  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Reclaim a previously-inherited table by its registered name. Returns
  `{:ok, tid}` if the keeper held it (after this call the caller owns
  it), or `:no_table` if the keeper never received it.

  Callers must re-install themselves as the new owner and re-register
  the heir; see the module doc.
  """
  @spec claim(atom()) :: {:ok, :ets.tid() | atom()} | :no_table
  def claim(table_name) when is_atom(table_name) do
    GenServer.call(__MODULE__, {:claim, table_name})
  end

  @doc """
  Canonical helper for heir-protected ETS owners. Reclaims the table
  from the keeper if it was previously inherited; otherwise creates a
  new named table. In both cases the keeper is registered as the heir,
  so the table survives the next owner crash.

  `extra_opts` are passed to `:ets.new/2` on the cold-start path; they
  must NOT include `:heir` (this function adds it). Default options are
  `[:named_table, :public, :set, read_concurrency: true]`.
  """
  @spec claim_or_new(atom(), [term()]) :: :ets.tid() | atom()
  def claim_or_new(name, extra_opts \\ [:named_table, :public, :set, read_concurrency: true])
      when is_atom(name) and is_list(extra_opts) do
    keeper = Process.whereis(__MODULE__)

    case claim(name) do
      {:ok, table} ->
        :ets.setopts(table, {:heir, keeper, :default_gift})
        table

      :no_table ->
        :ets.new(name, extra_opts ++ [{:heir, keeper, :default_gift}])
    end
  end

  @doc false
  @spec held() :: [atom()]
  def held do
    GenServer.call(__MODULE__, :held)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    {:ok, %{tables: %{}}}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from_pid, _gift}, state) do
    name = table_name(table)
    Logger.info("[EtsKeeper] Inherited table #{inspect(name)}")
    {:noreply, %{state | tables: Map.put(state.tables, name, table)}}
  end

  @impl true
  def handle_call({:claim, name}, {pid, _ref}, state) do
    case Map.pop(state.tables, name) do
      {nil, _} ->
        {:reply, :no_table, state}

      {table, remaining} ->
        :ets.give_away(table, pid, :reclaimed)
        Logger.info("[EtsKeeper] Gave table #{inspect(name)} to #{inspect(pid)}")
        {:reply, {:ok, table}, %{state | tables: remaining}}
    end
  end

  def handle_call(:held, _from, state) do
    {:reply, Map.keys(state.tables), state}
  end

  defp table_name(table) do
    case :ets.info(table, :name) do
      :undefined -> table
      name -> name
    end
  end
end
