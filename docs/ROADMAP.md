# Giulia Roadmap

Current status and planned evolution. Items marked DONE are implemented but listed
for historical context. Active items are ordered by priority.

---

## Implemented (kept for reference)

| Feature | Build | Status |
|---------|-------|--------|
| ETS multi-table optimization | - | Deferred (current O(files) scan is fast enough at 141 files) |
| Incremental indexing | 102 | DONE — SHA-256 content hashes, only stale files re-scanned |
| Cross-reference index | 94 | DONE — Property Graph tracks module + function call edges |
| Semantic search | 100 | DONE — Bumblebee embeddings, Nx.dot cosine similarity |
| CubDB persistence | 104 | DONE — warm starts, Merkle tree verification |
| ArcadeDB L2 | 137 | DONE — graph snapshots, consolidation queries |
| Dual-container architecture | 131 | DONE — worker + monitor via distributed Erlang |
| Discovery engine | 98 | DONE — 70 self-describing endpoints |

---

## Active Roadmap

### 1. Knowledge Endpoint Extensions

Extend existing endpoints with optional parameters to surface deeper metrics.
No new routes needed — these are filters/views on data we already compute.

#### `/api/knowledge/integrity` — add `single_impl` detection

**Current:** Returns behaviour/implementer consistency (fractures).
**Extension:** Add `implementer_count` to each behaviour entry. When called with
`?include_single_impl=true`, flag behaviours with exactly one implementing module.

Single-implementation interfaces are a code smell — the abstraction exists but only
one module uses it, meaning the interface adds indirection without actual polymorphism.

```
GET /api/knowledge/integrity?path=...&include_single_impl=true

{
  "status": "consistent",
  "fractures": [],
  "single_impl": [
    {"behaviour": "MyApp.Cache", "implementer": "MyApp.Cache.ETS", "callbacks": 3}
  ]
}
```

#### `/api/knowledge/dead_code` — add `unused_generalization` filter

**Current:** Returns functions defined but never called (static analysis).
**Extension:** Add `?group_by=mfa` to group arity variants together, and
`?exclude_tests=true` to ignore callsites from test files.

Unused generalizations are function arity variants (e.g., `foo/1`, `foo/2`, `foo/3`)
where only one variant has real callers — the others exist "just in case."

```
GET /api/knowledge/dead_code?path=...&group_by=mfa&exclude_tests=true

{
  "count": 3,
  "dead": [...],
  "unused_variants": [
    {"module": "Foo", "function": "bar", "arities": [1, 2, 3], "called_arities": [2]}
  ]
}
```

#### `/api/knowledge/god_modules` — add `facades` detection

**Current:** Returns modules ranked by combined complexity + centrality + function count.
**Extension:** Add `?include_facades=true` to flag shallow passthrough modules —
modules with zero private functions, high fan-out, and near-zero complexity.

Facades are not always bad (they simplify the public API), but a chain of facades
delegating to facades is unnecessary indirection. The `delegation_depth` field helps
identify when a request passes through 3+ modules before reaching real logic.

```
GET /api/knowledge/god_modules?path=...&include_facades=true

{
  "count": 20,
  "modules": [...],
  "facades": [
    {
      "module": "Giulia.Knowledge.Analyzer",
      "public_functions": 33,
      "private_functions": 0,
      "fan_out": 4,
      "complexity": 2,
      "delegates_to": ["Topology", "Metrics", "Behaviours", "Insights"]
    }
  ]
}
```

#### `/api/knowledge/heatmap` — add `isolated_complexity` risk type

**Current:** Returns per-module health scores (0-100) with red/yellow/green zones,
factoring centrality, complexity, test coverage, and coupling.
**Extension:** Add `?risk_type=isolated_complexity` to filter for modules with
high cyclomatic complexity but low fan-in (few callers).

These modules are complex but not depended upon — potential candidates for
simplification or removal. The inverse (high fan-in, low complexity) would be
a healthy utility module.

```
GET /api/knowledge/heatmap?path=...&risk_type=isolated_complexity

{
  "modules": [
    {
      "module": "Giulia.Client.Renderer",
      "complexity": 66,
      "centrality": 2,
      "fan_in": 2,
      "risk": "high complexity, low dependency — simplify or inline"
    }
  ]
}
```

---

### 2. ETS Store Optimization

**Priority:** Low (current O(files) scan handles 141 files in <1ms)
**Trigger:** When codebase exceeds ~500 modules or query latency becomes noticeable

Split the single `:set` table into specialized tables for O(1) lookups:

```elixir
:giulia_modules     # {:module, "Giulia.Foo"} => metadata
:giulia_functions   # {:function, "Giulia.Foo", :init, 1} => metadata (bag)
:giulia_specs       # {:spec, "Giulia.Foo", :init, 1} => spec string
:giulia_file_index  # {:file, "lib/foo.ex"} => [{:module, ...}, {:function, ...}] (bag)
```

Migration: dual-write during transition, migrate query functions one by one.

---

### 3. Owl TUI for Streaming Responses

**Priority:** Medium
**Status:** Dependency installed (`owl ~> 0.11`), not wired up

Live-render inference responses in the terminal with syntax highlighting,
diff previews, and approval prompts. Currently responses are plain text.

---

### 4. Constitution Enforcement in Reflection Step

**Priority:** Medium
**Status:** Constitution loaded and parsed, not enforced

The OODA inference loop has a REFLECT step that currently does nothing.
Wire it to check the model's proposed action against GIULIA.md taboos
and preferred patterns before executing.

---

### 5. File Watcher for Live Re-indexing

**Priority:** Low
**Trigger:** When manual `POST /api/index/scan` becomes tedious

Use `:fs` or `FileSystem` to watch project directories and trigger
incremental re-indexing on file save. The CubDB persistence layer
already handles incremental updates — this just adds the trigger.

---

### 6. Multi-Language Support via Tree-sitter Sidecar

**Priority:** Low
**Status:** Idea

Sourceror handles Elixir natively. For Python/TypeScript/Go analysis,
add tree-sitter as an optional sidecar (separate container or NIF).
The Property Graph schema is language-agnostic — only the parser changes.
