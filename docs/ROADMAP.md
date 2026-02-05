# Giulia Roadmap

Future evolution items and architectural improvements.

## ETS Store Optimization

**Status:** Planned
**Priority:** Medium
**Trigger:** When codebase exceeds ~100 modules or query latency becomes noticeable

### Current Implementation

Single `:set` table with per-file storage:

```elixir
:ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

# Key: {:ast, "lib/giulia/foo.ex"}
# Value: %{modules: [...], functions: [...], types: [...], ...}
```

All queries (e.g., `find_function/2`) require O(files) scan via `Enum.flat_map`.

### Proposed Evolution

Multiple specialized tables for O(1) lookups:

```elixir
# Module metadata (:set)
:giulia_modules
{{:module, "Giulia.Foo"}, %{file: "...", moduledoc: "...", line: 1}}

# Functions (:bag for multiple clauses/arities)
:giulia_functions
{{:function, "Giulia.Foo", :init, 1}, %{line: 10, type: :def, file: "..."}}
{{:function, "Giulia.Foo", :init, 1}, %{line: 15, type: :def, file: "..."}}

# Types (:set)
:giulia_types
{{:type, "Giulia.Foo", :my_type, 0}, %{visibility: :type, line: 5}}

# Specs (:set, keyed by function)
:giulia_specs
{{:spec, "Giulia.Foo", :init, 1}, %{spec: "...", line: 8}}

# Reverse index for re-indexing (:bag)
:giulia_file_index
{{:file, "lib/giulia/foo.ex"}, {:module, "Giulia.Foo"}}
{{:file, "lib/giulia/foo.ex"}, {:function, "Giulia.Foo", :init, 1}}
```

### Benefits

| Query | Current | Optimized |
|-------|---------|-----------|
| `find_function("init", 1)` | O(files) | O(1) |
| `find_module("Giulia.Foo")` | O(files) | O(1) |
| `list_functions("Giulia.Foo")` | O(files) | O(functions in module) |
| Re-index single file | O(1) | O(entries in file) |

### Migration Path

1. Add new tables alongside existing
2. Dual-write during transition
3. Migrate query functions one by one
4. Remove old table when stable

---

## Other Future Items

### Incremental Indexing

**Status:** Planned
**Trigger:** File watcher integration

Instead of full re-scan, watch for file changes and update only affected entries.

### Cross-Reference Index

**Status:** Idea
**Use Case:** "Who calls this function?"

Track call relationships:
```elixir
# :bag table
:giulia_calls
{{:calls, "Giulia.Foo", :bar, 2}, {"Giulia.Baz", :qux, 1, line: 45}}
```

### Semantic Search

**Status:** Idea
**Use Case:** "Find functions that handle authentication"

Embed function docs/names and store vectors for similarity search.
