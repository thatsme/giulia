# Pass 2 semantics pinned AS-IS: a project-internal `require` emits BOTH
#   => Golden.MacroUser -> Golden.Util :depends_on   (all import types)
#   => Golden.MacroUser -> Golden.Util :implements   (type in [:use, :require])
# The :implements label on a bare `require` is arguably over-broad — this
# golden pins the CURRENT extractor contract; tightening it is a deliberate
# semantic change that must update this golden in the same commit.
defmodule Golden.MacroUser do
  require Golden.Util

  def go, do: :ok
end
