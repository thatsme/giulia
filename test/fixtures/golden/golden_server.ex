# Pass 8 (behaviour dispatch): `use GenServer` + init/1, handle_call/3
#   => GenServer -> Golden.Server.init/1        {:calls, :behaviour_impl}
#   => GenServer -> Golden.Server.handle_call/3 {:calls, :behaviour_impl}
# Pass 4 (:direct): fully-qualified remote call
#   => Golden.Server.handle_call/3 -> Golden.Util.normalize/1 {:calls, :direct}
# Pass 5 (promotion): the :direct MFA edge promotes (no prior module edge)
#   => Golden.Server -> Golden.Util {:calls, :promoted}
# Pass 6: Golden.Util reference suppressed by the promoted module edge.
defmodule Golden.Server do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_call(:get, _from, state) do
    {:reply, Golden.Util.normalize(state), state}
  end
end
