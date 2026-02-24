# When Every Dashboard Line Goes Green — Builds 99-100

**How I eliminated the last slow endpoints and taught Giulia to recommend her own tools.**

---

In previous posts, I described Giulia — a persistent AI development agent built in Elixir that maintains a Knowledge Graph of your codebase, introspects running BEAM nodes, and validates refactoring plans before any code is written.

Builds 95-98 gave Giulia a nervous system for herself: a Logic Monitor dashboard that captures every internal event in real-time — OODA reasoning steps, LLM calls, tool executions, and every HTTP request from the AI assistant. A cognitive flight recorder.

The dashboard made something obvious. Two API calls were still slow. Visibly, embarrassingly slow.

Builds 99 and 100 fix that, and then go further.

## The Two Red Lines

The Logic Monitor timestamps every API call. Most endpoints return in 2-5ms — they read from pre-computed caches warmed eagerly after every Knowledge Graph rebuild. But two endpoints consistently showed triple-digit latencies:

- `dead_code` — 748ms
- `coupling` — 576ms

[SCREENSHOT: Logic Monitor dashboard showing API call timings]

Both were computing from scratch on every call. Every invocation parsed every source file through Sourceror, walked the AST with `Macro.prewalk`, and rebuilt the analysis from raw data. The same work, repeated identically, on every request.

Build 97 had already cached three metrics — heatmap, change_risk, and god_modules — with a shared Sourceror pass. But dead_code and coupling were left behind because they had different data shapes and separate code paths.

## Build 99: One Parse to Rule Them All

The core problem was duplication. The `coupling` function walked all ASTs to collect `{caller, callee, function_name}` triples. The internal `build_coupling_map` function walked the same ASTs to collect `{caller, callee}` pairs. Nearly identical Sourceror parses, nearly identical `Macro.prewalk` callbacks, run independently. Adding both to the background cache task would have parsed every source file twice.

The fix was surgical. One new function — `collect_remote_calls/1` — does a single Sourceror pass and collects the richer triples. Two derived functions produce the specific output each consumer needs:

- `coupling_from_calls/1` — groups by caller-callee pair, counts calls, lists functions. Same output as the standalone endpoint.
- `build_coupling_map_from_calls/1` — drops function names, computes max coupling to any single callee. Same output as the internal helper used by heatmap and change_risk.

For dead code, a parallel refactoring: `dead_code_with_asts/3` accepts pre-fetched AST data instead of re-fetching it from ETS. The standalone `dead_code/2` delegates to it. Zero caller changes.

The `compute_cached_metrics` function now computes all five heavy metrics from one AST fetch and one Sourceror pass:

```
all_asts        → [single fetch from ETS]
call_triples    → [single Sourceror pass]
coupling_map    → [derived from call_triples]
heatmap         → [uses coupling_map + all_asts]
change_risk     → [uses coupling_map + all_asts]
god_modules     → [uses all_asts]
dead_code       → [uses all_asts]
coupling        → [derived from call_triples]
```

Five metrics, one parse, computed in a background Task after every graph rebuild, cached in the GenServer state. Cold miss on any metric triggers a synchronous computation and caches the result for next time.

### The Result

| Metric | Before | After |
|--------|--------|-------|
| dead_code | 748ms | 2.5ms |
| coupling | 576ms | 2.8ms |
| heatmap | <10ms | 2.6ms |
| change_risk | <10ms | 2.4ms |
| god_modules | <10ms | 2.5ms |

Every metric, every call, under 3ms. Dashboard 100% green.

The pattern is worth noting: the optimization wasn't algorithmic cleverness. It was recognizing that two functions were doing the same work and merging them. The hardest performance bugs are the ones hiding in plain sight as "different functions that happen to read the same data."

## Build 100: The AI Recommends Its Own Tools

With caching complete, I turned to a different problem. Giulia has 55 API endpoints, organized across 9 domain routers. Each endpoint carries a `@skill` annotation describing its intent:

```elixir
@skill %{
  intent: "Find all modules that depend on a given module (downstream blast radius)",
  endpoint: "GET /api/knowledge/dependents",
  params: %{module: "required", path: "required"},
  category: "knowledge"
}
```

Build 98 made these skills discoverable via keyword search. But keyword search requires the AI to already know what it's looking for. If the user says "trace data flow through structs," the AI would need to know that the relevant endpoint is called `struct_lifecycle` — a name it might never guess.

Build 100 solves this with semantic matching.

### Just-In-Time Tool Recommendation

When Preflight runs (the mandatory pre-planning checklist), it already embeds the user's prompt for semantic search. Build 100 adds one step: after discovering relevant modules, it takes the same prompt embedding and searches against all 55 skill intents.

The skill intents are embedded once (lazy-initialized on first call) and cached in the GenServer state. Each subsequent Preflight call adds near-zero latency — one matrix multiplication and a top-k extraction.

The result: Preflight now returns a `suggested_tools` array alongside the usual contract checklists:

```
Prompt: "trace data flow through structs"

suggested_tools:
  1. struct_lifecycle (0.885 relevance) — "Trace struct lifecycle (data flow across modules)"
  2. trace (0.757)            — "Trace function calls for a module"
  3. audit (0.715)            — "Run unified audit"
  4. monitor (0.687)          — "Open the Logic Monitor dashboard"
  5. integrity (0.687)        — "Check behaviour-implementer integrity"
```

```
Prompt: "assess blast radius before refactoring a hub module"

suggested_tools:
  1. dependents (0.854)       — "Find all modules that depend on a given module"
  2. unprotected_hubs (0.703) — "Find hub modules with low spec/doc coverage"
  3. coupling (0.690)         — "Analyze coupling between module pairs"
  4. centrality (0.670)       — "Get centrality score for a module"
  5. audit (0.657)            — "Run unified audit"
```

The ranking shifts with intent. Ask about data flow, you get struct analysis tools. Ask about blast radius, you get dependency and centrality tools. The AI assistant learns about the right endpoints exactly when it needs them, not before.

### Graceful Degradation

If the embedding model isn't loaded (EmbeddingServing unavailable), `suggested_tools` returns an empty array. Preflight continues to work exactly as before. Zero failure modes, zero breaking changes to the existing API.

## Why This Matters

Most AI tools solve the discovery problem with documentation. Write better docs, stuff more context into the system prompt, hope the model remembers the right endpoint at the right time. This works until you have 55 endpoints and the model's context window is a scarce resource.

Giulia inverts this. Instead of front-loading documentation, she surfaces relevant tools at the moment of planning — when the AI knows what it's about to do and can evaluate which tools would help. The context cost is 5 small JSON objects, not a 300-line API reference.

This is the difference between handing someone a phonebook and handing them the three numbers they're about to need.

## The Numbers

|                          | Build 98  | Build 100 |
|--------------------------|-----------|-----------|
| Cached Metrics           | 3         | 5         |
| Slowest Endpoint (warm)  | 748ms     | 2.8ms     |
| API Endpoints            | 55        | 55        |
| Skill Vectors Embedded   | 0         | 55        |
| Preflight Response Fields| 6         | 7         |
| Tests                    | 660       | 660       |

Two modified modules in Analyzer (shared Sourceror pass), two cache-first patterns in Store, one GenServer extension in SemanticIndex, one pipeline step in Preflight. 348 lines added, 75 removed. Zero breaking changes.

---

*Giulia is a personal project built in Elixir on the BEAM. Builds 99-100 were implemented in a single session with Claude Code, verified with `docker compose build` (660 tests, 0 failures), and tested live against the running daemon. The Logic Monitor that revealed the slow endpoints was itself built in Build 95 — the tool keeps finding its own work.*

*If you're working on developer tooling, semantic code intelligence, or caching strategies for AST-heavy analysis, I'd love to connect.*
