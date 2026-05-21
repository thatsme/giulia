# Dialyzer warnings to ignore.
# Each entry should have a comment explaining WHY it's ignored.
# Stale entries are surfaced by `list_unused_filters: true` in mix.exs.
[
  # CubDB.put_multi/2 — Dialyzer reads its typespec as map-only, so it judges
  # the call at writer.ex:305 unsatisfiable. CubDB accepts an enumerable of
  # {key, value} pairs at runtime; the persistence and warm-restore suites pass.
  {"lib/giulia/persistence/writer.ex", :call},
  # update_merkle_tree/3 "never called" is a knock-on of the same false
  # positive — Dialyzer sees the code after the put_multi call as unreachable.
  {"lib/giulia/persistence/writer.ex", :unused_fun}
]
