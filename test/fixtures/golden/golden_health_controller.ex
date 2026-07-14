# Route target — check/2 must exist as a function vertex or Pass 9
# refuses the dispatch edge (vertex-gated, arity 2 by Phoenix convention).
defmodule Golden.HealthController do
  def check(conn, params), do: {conn, params}
end
