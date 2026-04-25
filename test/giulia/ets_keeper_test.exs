defmodule Giulia.EtsKeeperTest do
  @moduledoc """
  Verifies the heir contract: when an owner registered with EtsKeeper
  as heir dies, the table data survives, and a new owner reclaims it
  via `claim_or_new/2`.

  These tests use private table names (one per test) so they don't
  collide with the live `:giulia_knowledge_graphs` / `Giulia.Context.Store`
  tables that the daemon's EtsKeeper is already holding for.
  """
  use ExUnit.Case, async: false

  alias Giulia.EtsKeeper

  test "fresh owner gets a new table when keeper has nothing" do
    name = :"ets_keeper_test_fresh_#{System.unique_integer([:positive])}"

    table =
      run_as_owner(fn ->
        EtsKeeper.claim_or_new(name)
      end)

    assert :ets.info(table) != :undefined
    assert :ets.info(table, :name) == name
    # heir is the live keeper
    assert :ets.info(table, :heir) == Process.whereis(EtsKeeper)
  after
    safe_delete_owned_by_keeper(:"ets_keeper_test_fresh_#{System.unique_integer([:positive])}")
  end

  test "data survives owner death and reclaim transfers it back" do
    name = :"ets_keeper_test_survive_#{System.unique_integer([:positive])}"

    # First owner: create + insert some data, then die.
    {pid, ref} =
      spawn_owner(fn ->
        _table = EtsKeeper.claim_or_new(name)
        :ets.insert(name, {:k1, "value1"})
        :ets.insert(name, {:k2, "value2"})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Wait briefly for ETS-TRANSFER to land in keeper's mailbox.
    wait_until_held(name, 1_000)

    # Data is still readable directly via the named table — heir owns it now.
    assert :ets.lookup(name, :k1) == [{:k1, "value1"}]
    assert :ets.lookup(name, :k2) == [{:k2, "value2"}]

    # Second owner: claim it back. Data is preserved.
    {table, second_pid} =
      run_as_owner_returning_pid(fn ->
        EtsKeeper.claim_or_new(name)
      end)

    assert table == name
    assert :ets.lookup(name, :k1) == [{:k1, "value1"}]
    assert :ets.info(name, :owner) == second_pid

    # heir was re-installed on reclaim
    assert :ets.info(name, :heir) == Process.whereis(EtsKeeper)

    # Cleanup: kill the second owner so the keeper isn't left holding
    # this test's table forever.
    Process.exit(second_pid, :kill)
    wait_until_held(name, 1_000)
    safe_delete_owned_by_keeper(name)
  end

  test "claim returns :no_table when the keeper never received it" do
    assert EtsKeeper.claim(:"definitely_never_existed_#{System.unique_integer([:positive])}") ==
             :no_table
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Run a function in a short-lived owner process and return its result.
  # The owner stays alive only long enough to execute the fn; it then exits
  # normally, which in ETS-land means the table goes to the heir.
  defp run_as_owner(fun) do
    parent = self()

    pid =
      spawn(fn ->
        result = fun.()
        send(parent, {:result, result})
        # Stay alive briefly so caller can inspect the table while we still own it.
        receive do
          :die -> :ok
        after
          200 -> :ok
        end
      end)

    receive do
      {:result, result} ->
        send(pid, :die)
        result
    after
      1_000 -> flunk("owner did not return result")
    end
  end

  defp run_as_owner_returning_pid(fun) do
    parent = self()

    spawn(fn ->
      result = fun.()
      send(parent, {:result, result, self()})

      receive do
        :die -> :ok
      after
        5_000 -> :ok
      end
    end)

    receive do
      {:result, result, owner_pid} -> {result, owner_pid}
    after
      1_000 -> flunk("owner did not return result")
    end
  end

  defp spawn_owner(fun) do
    pid =
      spawn(fn ->
        fun.()
        :ok
      end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp wait_until_held(name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_held(name, deadline)
  end

  defp do_wait_until_held(name, deadline) do
    if name in EtsKeeper.held() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("table #{inspect(name)} was never inherited by EtsKeeper")
      else
        Process.sleep(20)
        do_wait_until_held(name, deadline)
      end
    end
  end

  # When a test's owner is killed and the keeper inherits the table, the
  # keeper holds it forever (no claim happens). Drain it so subsequent
  # test runs aren't polluted.
  defp safe_delete_owned_by_keeper(name) do
    case EtsKeeper.claim(name) do
      {:ok, table} -> :ets.delete(table)
      :no_table -> :ok
    end
  rescue
    _ -> :ok
  end
end
