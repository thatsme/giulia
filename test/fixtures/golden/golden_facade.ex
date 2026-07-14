# defdelegate pass (runs with Pass 5, before references): module-level
# :depends_on per `to:` target. Two keyword shapes pinned deliberately —
# Sourceror wraps keyword keys in {:__block__, _, [:to]}, so the matcher
# must tolerate wrapped AND plain forms, single- and multi-pair opts:
#   => Golden.Facade -> Golden.Util :depends_on   (single-pair `to:`)
#   => Golden.Facade -> Golden.Data :depends_on   (two-pair `to: ..., as:`)
# Pass 6: both aliases suppressed by these module edges.
# History: until the Sourceror keyword-shape fix these degraded to
# :references — a real under-extraction found by this golden's maiden run.
defmodule Golden.Facade do
  defdelegate normalize(value), to: Golden.Util

  defdelegate build(field), to: Golden.Data, as: :from_field
end
