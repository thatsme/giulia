# Pass 4 (:local): unqualified same-module call
#   => Golden.Util.normalize/1 -> Golden.Util.scrub/1 {:calls, :local}
# Same-module edges never promote (caller_mod == callee_mod).
defmodule Golden.Util do
  def normalize(value), do: scrub(value)

  defp scrub(value), do: value
end
