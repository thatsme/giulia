# THE BUG CLASS (pinned 2026-07-14, commit f515d2e). This module calls
# bare stdlib `Application.get_env/2` while the fixture project contains
# a `Golden.Application` module — the exact collision that fabricated
# `X -> MyApp.Application :references` edges in every analyzed project
# before the resolve_with_fallback/4 guard. `Version.parse/1` pins the
# same class for any stdlib name colliding with a project-style suffix.
#
# GOLDEN: Golden.Config has ZERO outgoing edges of any label.
defmodule Golden.Config do
  def fetch do
    _ = Version.parse("1.0.0")
    Application.get_env(:golden, :key)
  end
end
