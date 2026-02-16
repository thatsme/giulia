# Giulia Architecture (Build 90)

## Overview

Giulia is a high-performance code intelligence daemon built on the Erlang/OTP platform. It runs as a **persistent background service** exposing AST analysis, a Knowledge Graph, semantic search, and transactional code modification capabilities via a REST API on port 4000.

**Primary consumer: Claude Code.** Giulia acts as a sidecar daemon that Claude Code queries for module inspection, blast radius analysis, dependency topology, preflight contract checks, and orchestrated code modifications. All intelligence endpoints are consumed via HTTP — Giulia does not call LLM providers directly in production.

The key architectural insight: **Claude Code is the brain, Giulia is the exoskeleton.** Without the exoskeleton, the brain is just dreaming; without the brain, the exoskeleton is just a pile of metal.

### At a Glance (Build 90)

| Metric | Value |
|--------|-------|
| Modules | 72 |
| Functions | 1,007 |
| Type Specs | 212 |
| Types | 47 |
| Structs | 6 |
| Callbacks | 7 |
| Tools | 24 |
| Knowledge Graph Vertices | 1,079 |
| Knowledge Graph Edges | 1,309 |
| HTTP API Endpoints | ~50 |

---

## 1. Daemon-Client Architecture

Giulia is designed as a system-wide service that external AI agents (primarily Claude Code) query for code intelligence:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SYSTEM-WIDE DEPLOYMENT                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Claude Code (Terminal A)              Claude Code (Terminal B)             │
│  ┌─────────────────────────────┐      ┌─────────────────────────────┐       │
│  │  Working on: ~/alpha        │      │  Working on: ~/beta         │       │
│  │                             │      │                             │       │
│  │  curl /api/knowledge/impact │      │  curl /api/index/functions  │       │
│  │  curl /api/briefing/preflight      │  curl /api/knowledge/stats  │       │
│  └────────┬────────────────────┘      └────────┬────────────────────┘       │
│           │                                    │                             │
│           │         HTTP GET/POST :4000         │                             │
│           │         ┌──────────────────────────┴──────────────────────┐     │
│           │         │                                                  │     │
│           ▼         ▼                                                  │     │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                     GIULIA DAEMON (Docker/BEAM)                     │     │
│  │                       HTTP API on :4000                             │     │
│  │  ┌──────────────────┐    ┌──────────────────┐                      │     │
│  │  │  ContextManager  │───▶│  ProjectContext  │ (alpha)              │     │
│  │  │   (Router)       │    │  - AST Index     │                      │     │
│  │  │                  │    │  - Constitution  │                      │     │
│  │  │                  │    │  - Transaction   │                      │     │
│  │  │                  │    └──────────────────┘                      │     │
│  │  │                  │    ┌──────────────────┐                      │     │
│  │  │                  │───▶│  ProjectContext  │ (beta)               │     │
│  │  │                  │    │  - AST Index     │                      │     │
│  │  │                  │    │  - Constitution  │                      │     │
│  │  │                  │    │  - Transaction   │                      │     │
│  │  └──────────────────┘    └──────────────────┘                      │     │
│  │                                                                     │     │
│  │  ┌──────────────────┐    ┌──────────────────┐                      │     │
│  │  │  Knowledge Graph │    │ Semantic Index   │                      │     │
│  │  │  (libgraph)      │    │ (Bumblebee)      │                      │     │
│  │  └──────────────────┘    └──────────────────┘                      │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why HTTP Instead of Erlang Distribution?

Erlang distribution requires bi-directional connections. When a client connects to the daemon, the daemon tries to connect BACK to the client. Inside Docker:
- `127.0.0.1` means the container's loopback, not the host
- The return connection fails because IPs don't mean the same thing
- EPMD (Erlang Port Mapper Daemon) adds another layer of complexity

**The Solution: Simple HTTP/JSON via Bandit.** HTTP is unidirectional — client sends request, server responds. No return connection needed. Port forwarding works perfectly.

### Why Daemon?

1. **Hot AST Cache**: Don't re-index 72 files every Claude Code session.
2. **Knowledge Graph**: 1,079 vertices + 1,309 edges precomputed — instant topology queries.
3. **Multi-Project**: Work on alpha and beta simultaneously, isolated contexts.
4. **Stateful Intelligence**: Semantic embeddings, behaviour integrity, struct lifecycle — all pre-computed and ready.
5. **System-Wide**: Any agent on the machine can query `localhost:4000`.

### Typical Query Flow (Claude Code → Giulia)

```
Claude Code needs blast radius before modifying Context.Store:

1. Claude Code → GET http://localhost:4000/api/knowledge/impact
      ?path=C:/Development/GitHub/Giulia&module=Giulia.Context.Store&depth=2

2. Daemon's PathMapper translates host path → container path
   Knowledge.Store queries the precomputed Graph.t()

3. Response: {upstream: [...], downstream: [...], function_edges: [...]}

4. Claude Code uses this to plan safe modifications
```

For the OODA orchestrator path (autonomous code modification):

```
Claude Code → POST /api/command/stream
   Body: {"message": "rename function X to Y", "path": "C:/..."}

1. ContextManager resolves ProjectContext
2. Router classifies task → selects provider (if configured)
3. Orchestrator runs OODA loop: THINK → VALIDATE → EXECUTE → OBSERVE
4. SSE events stream tool calls and results in real-time
5. Final response returned
```

---

## 2. Supervision Tree

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            BEAM VM (Erlang)                               │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  Giulia.Supervisor (one_for_one)                                         │
│  ├── 1.  Registry           — Named process lookup (Elixir Registry)     │
│  ├── 2.  Context.Store      — ETS table owner (AST metadata)             │
│  ├── 3.  Tools.Registry     — Auto-discovers 24 tools on boot            │
│  ├── 4.  Context.Indexer    — Background AST scanner (Task.async_stream) │
│  ├── 5.  Knowledge.Store    — Knowledge Graph (libgraph + GenServer)     │
│  ├── 6.  EmbeddingServing   — Bumblebee model serving (optional)         │
│  ├── 7.  SemanticIndex      — Vector search over embeddings              │
│  ├── 8.  Provider.Sup       — DynamicSupervisor for API connections      │
│  ├── 9.  Inference.Trace    — Black-box recorder for debugging           │
│  ├── 10. Inference.Events   — Pub/sub for SSE streaming                  │
│  ├── 11. Inference.Approval — Human-in-the-loop consent gate             │
│  ├── 12. Inference.Sup      — Pool + Orchestrators (back-pressure)       │
│  ├── 13. ProjectSupervisor  — DynamicSupervisor for ProjectContexts      │
│  ├── 14. ContextManager     — Routes path → ProjectContext               │
│  └── 15. Bandit             — HTTP server on :4000 (Plug.Router)         │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

### Why This Order Matters

OTP guarantees children start in order. Each child depends on the ones above it:
- **Store** must exist before **Indexer** can write AST data
- **Knowledge.Store** needs Store + Indexer data to build the graph
- **EmbeddingServing** returns `:ignore` if the model fails to load (non-fatal)
- **SemanticIndex** depends on both Store and EmbeddingServing
- **Inference.Supervisor** needs providers, tools, and trace/events
- **ContextManager** depends on ProjectSupervisor for spawning contexts
- **Bandit** starts last so all services are ready before accepting requests

---

## 3. Module Architecture

### Layer Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                          HTTP API Layer                               │
│  Daemon.Endpoint (Plug.Router) — 50+ routes, SSE streaming          │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                       Inference Layer (OODA Loop)                     │
│  ┌─────────────┐  ┌────────┐  ┌────────────┐  ┌──────────────────┐ │
│  │ Orchestrator │──│ Engine │──│ToolDispatch│──│  ContextBuilder  │ │
│  │  (GenServer) │  │ (OODA) │  │  (execute) │  │   (prompts)     │ │
│  └──────┬──────┘  └────────┘  └────────────┘  └──────────────────┘ │
│         │                                                            │
│  ┌──────▼──────┐  ┌────────────┐  ┌────────────┐  ┌─────────────┐ │
│  │    State    │  │Transaction │  │Verification│  │  Escalation │ │
│  │  (pure fn) │  │  (staging) │  │ (compile)  │  │ (cloud fix) │ │
│  └─────────────┘  └────────────┘  └────────────┘  └─────────────┘ │
│  ┌─────────────┐  ┌────────────┐  ┌────────────┐  ┌─────────────┐ │
│  │  RenameMFA  │  │BulkReplace │  │   Events   │  │  Approval   │ │
│  │ (refactor)  │  │ (mass edit)│  │ (pub/sub)  │  │ (consent)   │ │
│  └─────────────┘  └────────────┘  └────────────┘  └─────────────┘ │
│  ┌─────────────┐  ┌────────────┐  ┌────────────┐                  │
│  │ResponseParser│ │    Pool    │  │   Trace    │                  │
│  │  (JSON fix) │  │(back-press)│  │(black box) │                  │
│  └─────────────┘  └────────────┘  └────────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                      Intelligence Layer                              │
│  ┌─────────────┐  ┌──────────────────┐  ┌─────────────────────┐    │
│  │  Preflight  │  │ SurgicalBriefing │  │   SemanticIndex     │    │
│  │ (6 contracts│  │ (Layer 1+2 pre-  │  │ (Bumblebee cosine   │    │
│  │  per module)│  │  processing)     │  │  search + dedup)    │    │
│  └─────────────┘  └──────────────────┘  └─────────────────────┘    │
│  ┌──────────────────┐                                               │
│  │ EmbeddingServing │                                               │
│  │ (384-dim model)  │                                               │
│  └──────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                       Knowledge Layer                                │
│  ┌─────────────┐  ┌────────────┐  ┌────────────┐  ┌─────────────┐ │
│  │   Store     │  │  Builder   │  │  Analyzer   │  │  MacroMap   │ │
│  │ (GenServer) │  │ (4-pass    │  │ (pure graph │  │ (use X →    │ │
│  │ owns Graph  │  │  graph     │  │  analytics) │  │  injections)│ │
│  │             │  │  build)    │  │             │  │             │ │
│  └─────────────┘  └────────────┘  └────────────┘  └─────────────┘ │
│                                                                      │
│  Analytics: centrality, impact_map, blast_radius, dead_code,        │
│  cycles, god_modules, coupling, fan_in_out, heatmap, change_risk,   │
│  behaviour_integrity, struct_lifecycle, unprotected_hubs,            │
│  pre_impact_check, logic_flow, style_oracle, semantic_duplicates    │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                         Context Layer                                │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐              │
│  │   Store     │  │  Indexer   │  │ ProjectContext  │              │
│  │   (ETS)     │  │ (parallel  │  │ (per-project    │              │
│  │             │  │  scanner)  │  │  GenServer)     │              │
│  └─────────────┘  └────────────┘  └────────────────┘              │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐              │
│  │ContextMgr   │  │ PathSandbox│  │  PathMapper    │              │
│  │(path router)│  │ (security) │  │ (host↔container│              │
│  └─────────────┘  └────────────┘  └────────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                          AST Layer                                   │
│  AST.Processor (Sourceror) — parse, analyze, patch, slice           │
│  27 public functions: extract_functions, extract_specs,              │
│  extract_types, estimate_complexity, patch_function,                 │
│  slice_function_with_deps, insert_function, ...                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                    Provider Layer (dormant in production)             │
│  5 providers implemented: LM Studio, Anthropic, Ollama, Gemini,     │
│  Groq — retained for future standalone operation.                    │
│  Router classifies task intensity → selects provider + fallback.     │
│  In production: Claude Code handles all LLM reasoning externally.    │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────┐
│                          Tools Layer                                 │
│  24 auto-discovered tools via Tools.Registry                        │
│                                                                      │
│  Read:    read_file, list_files, get_function, get_context,         │
│           get_module_info, lookup_function, search_code,             │
│           search_meaning, get_impact_map, trace_path,               │
│           cycle_check, get_staged_files                              │
│                                                                      │
│  Write:   write_file, edit_file, write_function, patch_function,    │
│           bulk_replace, rename_mfa, commit_changes                   │
│                                                                      │
│  Control: think, respond, run_mix, run_tests                        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. The Inference Pipeline (OODA Loop)

> **Dual-mode architecture:** In production, Claude Code queries Giulia's read-only endpoints (index, knowledge, intelligence) and handles all reasoning externally. The OODA orchestrator described below is used when Giulia operates autonomously with its own LLM providers — this path is fully implemented but dormant in the current deployment.

When operating autonomously, we don't just send prompts — we manage a **State Machine** that constrains, corrects, and verifies the model at every step.

### Architecture After Refactoring (Builds 74-84)

The original monolithic Orchestrator (4,736 lines, complexity score 996) was decomposed into focused modules:

| Module | Responsibility | Lines | Purity |
|--------|---------------|-------|--------|
| `Orchestrator` | Thin GenServer shell, OTP message translation | ~200 | GenServer |
| `Engine` | OODA loop core, provider calls, response routing | ~600 | Stateless (returns directives) |
| `State` | Pure-functional state management (~50 functions) | ~350 | Pure |
| `ToolDispatch` | Tool execution, staging, approval gating | ~400 | Stateless |
| `ContextBuilder` | Message construction, previews, interventions | ~450 | Stateless |
| `Transaction` | Staging buffer, rollback, integrity checks | ~350 | Pure |
| `Verification` | Compile checks, baseline tracking | ~150 | Pure |
| `Escalation` | Cloud provider escalation for stuck errors | ~200 | Stateless |
| `RenameMFA` | Cross-file module/function/arity rename | ~300 | Stateless |
| `BulkReplace` | Mass pattern replacement across files | ~200 | Stateless |
| `ResponseParser` | JSON extraction + repair from LLM output | ~150 | Pure |

**Design principle:** The Orchestrator's only job is translating OTP messages to `Engine.dispatch/2` calls and directives back to GenServer tuples.

**Directive pattern:**
```elixir
{:next, action, state}  → {:noreply, state, {:continue, action}}
{:done, result, state}  → send_reply + reset_state
{:halt, state}          → {:noreply, state}  (paused / waiting for approval)
```

### OODA State Machine

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     ORCHESTRATOR STATE MACHINE                            │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐           │
│  │  THINK   │───▶│ VALIDATE │───▶│ REFLECT  │───▶│ EXECUTE  │           │
│  │  (LLM)   │    │ (Schema) │    │  (AST)   │    │ (Tools)  │           │
│  └──────────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘           │
│       ▲               │               │               │                  │
│       │          ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐           │
│       │          │CORRECTION│    │INTERCEPT │    │OBSERVATION│           │
│       │          │  (retry) │    │ (block)  │    │ (result) │           │
│       │          └────┬─────┘    └────┬─────┘    └────┬─────┘           │
│       │               │               │               │                  │
│       └───────────────┴───────────────┴───────────────┘                  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  SAFETY MECHANISMS                                                  │  │
│  │                                                                      │  │
│  │  Loop Prevention:    consecutive_failures ≥ 3 → intervention       │  │
│  │  Repeat Detection:   same action twice → force redirect            │  │
│  │  Max Iterations:     default 20, auto-bumped on progress           │  │
│  │  Escalation:         syntax failures ≥ 2 → cloud Senior Architect  │  │
│  │  Approval Gate:      hub module writes → human consent required    │  │
│  │  Transaction Mode:   hub writes staged, compile-verified, atomic   │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  State tracks: iteration, failures, syntax_failures, repeat_count,       │
│  action_history, modified_files, test_status, baseline, goal_coverage    │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

### Verification Pipeline

Every tool execution passes through a multi-stage pipeline:

1. **VALIDATE** — Schema as Law
   - Model sends JSON action
   - `ResponseParser` extracts JSON (handles markdown fences, unclosed braces, chat preamble)
   - Ecto changeset validates structure per tool
   - Missing fields → Correction sent back to model

2. **REFLECT** — Skeptical Supervisor
   - `ContextBuilder` checks hub risk via Knowledge Graph centrality
   - File doesn't exist? Check for similar paths (Jaro distance > 0.7)
   - Destructive action on hub module? → Approval gate or transaction mode
   - Problem found → Intercept, don't execute

3. **EXECUTE** — Guarded Action (via `ToolDispatch`)
   - Only runs if validation AND reflection pass
   - Write tools (`write_file`, `edit_file`, `patch_function`, `write_function`) may be staged
   - Results become OBSERVATION for next iteration
   - Modified files tracked for verification

4. **VERIFY** — Post-execution
   - `Verification` runs `mix compile --all-warnings` after write operations
   - Compile errors → correction message with file + error context
   - Syntax failures ≥ 2 → escalation to cloud Senior Architect (Gemini/Groq)
   - Transaction mode: staged files compile-tested before commit to disk

### Escalation Protocol (OODA Mode)

When using the OODA orchestrator with local providers, if the primary model fails repeatedly on syntax errors:

```
Local model fails compile × 2
    → Escalation.build_prompt/3 creates Senior Architect prompt
    → Tries Gemini first, falls back to Groq
    → Senior returns surgical patch (patch_function or LINE:N format)
    → Escalation.apply_line_fix/4 applies the fix
    → Re-verify compilation
```

> In Claude Code mode (production), escalation is unnecessary — Claude handles error recovery directly.

### Approval Gate

For writes to high-centrality modules (hubs), `ToolDispatch` can trigger the human-in-the-loop approval gate:

```elixir
# In ToolDispatch
ContextBuilder.assess_hub_risk(tool_name, params, state)
# → {:high_risk, %{module: "Store", degree: 21, ...}}

# Gate activates:
Approval.request_approval(id, tool_name, params, preview, request_id)
# → SSE event: {type: :approval_required, ...}
# → Orchestrator halts until POST /api/approval/:id

# User responds:
POST /api/approval/:id {"approved": true}
# → Orchestrator resumes execution
```

---

## 5. Transaction System

The Transactional Exoskeleton (build 75+) provides atomic multi-file modifications:

```
┌───────────────────────────────────────────────────────────────┐
│                    TRANSACTION FLOW                             │
│                                                                │
│  1. Auto-enable: hub module detected (centrality ≥ 3)         │
│  2. Stage: write_file/edit_file → staging_buffer (in-memory)  │
│  3. Overlay: subsequent read_file sees staged content         │
│  4. Verify: compile staged files via temp-file strategy       │
│  5. Integrity: behaviour contracts checked (no fractures)     │
│  6. Commit: staging_buffer → disk (atomic)                    │
│  7. Rollback: on failure, restore from staging_backups        │
│                                                                │
│  Pure struct — no GenServer coupling:                          │
│  %Transaction{mode, staging_buffer, staging_backups, lock}    │
└───────────────────────────────────────────────────────────────┘
```

Key properties:
- **Read-with-overlay**: `Transaction.read_with_overlay/2` returns staged content if available, disk otherwise. The model always sees the "latest truth."
- **Integrity checks**: `Transaction.integrity_check/3` verifies behaviour contracts aren't broken by staged changes.
- **Auto-regression**: On commit, runs `mix compile` against staged content. Failures trigger rollback.
- **Backup originals**: Every staged file's original content (or `:new_file` marker) is preserved for rollback.

---

## 6. Knowledge Graph

The Knowledge Graph (builds 80-89) provides topological intelligence over the codebase.

### Construction (Knowledge.Builder)

A pure-functional 4-pass graph builder:

| Pass | What It Does | Edge Type |
|------|-------------|-----------|
| 1. Vertices | Adds module, function, struct, behaviour vertices | — |
| 2. Dependencies | Module-level `alias`, `import`, `use` edges | `:depends_on` |
| 3. Xref | BEAM-compiled cross-reference edges | `:calls` |
| 4. Function Calls | AST walk of every function body — MFA→MFA edges | `:calls` |

Pass 4 is the most expensive but most valuable: it produces fine-grained function-level call edges (238 → 1,181 edges in build 80).

### Storage (Knowledge.Store — GenServer)

Owns the `Graph.t()` struct. Rebuilds on every index scan. All queries go through the GenServer for serialized access to the graph.

### Analytics (Knowledge.Analyzer — Pure Functions)

All analytical functions are stateless — they take a `Graph.t()` and return computed metrics:

| Analysis | Description |
|----------|-------------|
| `centrality/2` | In-degree, out-degree, hub score per module |
| `impact_map/3` | Upstream + downstream blast radius at depth N |
| `dependents/2` | Direct + transitive downstream consumers |
| `dependencies/2` | Direct + transitive upstream suppliers |
| `trace_path/3` | Shortest path (Dijkstra) between two modules |
| `logic_flow/4` | Function-level MFA→MFA path tracing |
| `dead_code/2` | Functions defined but never called (excluding OTP callbacks) |
| `cycles/1` | Strongly connected components (circular deps) |
| `god_modules/2` | High complexity + centrality + function count |
| `coupling/1` | Function-level dependency strength between module pairs |
| `fan_in_out/2` | Dependency direction imbalance per module |
| `change_risk/2` | Composite refactoring priority score |
| `heatmap/2` | Module health scores 0-100 (centrality 30%, complexity 25%, test coverage 25%, coupling 20%) |
| `behaviour_integrity/3` | Callback contract verification (with optional + macro ghost heuristic) |
| `struct_lifecycle/2` | Struct data flow: creators, consumers, logic leaks |
| `pre_impact_check/3` | Rename/remove risk analysis with phased migration plan |
| `style_oracle/3` | Exemplar functions matching a concept (quality-gated: @spec + @doc) |

### MacroMap (Knowledge.MacroMap)

Static knowledge base mapping `use Module` to injected function signatures. Prevents false-positive behaviour fractures (e.g., `use GenServer` injects `init/1`, `handle_call/3`, etc. — these shouldn't be flagged as "missing implementations").

### Top 5 Hubs (Build 90)

| Module | Degree | Role |
|--------|--------|------|
| `Tools.Registry` | 30 | Tool discovery and dispatch |
| `Context.Store` | 21 | ETS-backed project state |
| `Inference.Engine` | 18 | OODA loop core |
| `Daemon.Endpoint` | 17 | HTTP API surface |
| `Knowledge.Store` | 14 | Graph owner |

---

## 7. Intelligence Layer

Pre-processing layers that run BEFORE the LLM, providing structured context to improve model accuracy.

### Layer 1: Semantic Search (SemanticIndex)

- Uses Bumblebee (`all-MiniLM-L6-v2`, 384 dimensions) for embedding
- Indexes all modules and functions on scan
- Cosine similarity search: "error handling" → finds relevant functions
- Duplicate detection: clusters functions with similarity ≥ threshold

### Layer 2: Surgical Briefing (SurgicalBriefing)

Combines semantic search results with Knowledge Graph topology to produce a focused briefing. Filters by relevance threshold so the model doesn't get noise.

### Layer 3: Preflight Contract Checklist (Preflight)

The single most powerful pre-processing call. Given a natural language prompt:

1. **Discover** — semantic search for target modules
2. **Pre-compute** — change risk scores (expensive, called once)
3. **Per-module** — build 6 contract sections:

| Contract | Content |
|----------|---------|
| Behaviour | Callbacks defined/implemented, integrity status |
| Type | Specs, types, coverage ratio |
| Data | Struct fields, dependents, lifecycle |
| Macro | `use` directives, injected functions (via MacroMap) |
| Topology | Centrality, impact map, change risk score |
| Semantic | Similarity to prompt, drift detection |

4. **Summarize** — red/yellow/green risk levels, action recommendations

One call replaces the 4+ separate queries previously required for planning mode.

### Principal Consultant (Build 89 — Unified Audit)

Four specialized analyses combined into a single endpoint (`/api/knowledge/audit`):

| Feature | What It Finds |
|---------|--------------|
| **Unprotected Hubs** | Hub modules (in-degree ≥ N) with low spec/doc coverage |
| **Struct Lifecycle** | Data flow tracing: which modules create/consume each struct, logic leaks |
| **Semantic Duplicates** | Clusters of functionally similar functions (cosine ≥ 0.85) |
| **Behaviour Integrity** | Enriched contract checks with optional callbacks + macro ghost heuristic |

---

## 8. Provider Layer (Dormant)

> **Note:** In production, Giulia is consumed by Claude Code via the HTTP API. The provider layer exists in code but is not actively used — Claude Code handles all LLM reasoning externally. The provider infrastructure is retained for future standalone operation.

### Provider Behaviour

```elixir
@callback chat(messages, opts) :: {:ok, response} | {:error, term}
@callback chat(messages, tools, opts) :: {:ok, response} | {:error, term}
@callback stream(messages, opts) :: {:ok, Enumerable.t()} | {:error, term}
```

### Implemented Providers

| Provider | Module | Endpoint | Intended Use Case |
|----------|--------|----------|-------------------|
| LM Studio | `Provider.LMStudio` | localhost:1234 | Local, sub-second micro-tasks |
| Anthropic | `Provider.Anthropic` | api.anthropic.com | Cloud, heavy reasoning |
| Ollama | `Provider.Ollama` | localhost:11434 | Local, medium tasks |
| Gemini | `Provider.Gemini` | generativelanguage.googleapis.com | Cloud, escalation fallback |
| Groq | `Provider.Groq` | api.groq.com | Cloud, fast escalation |

### Task Router

`Provider.Router` classifies tasks by intensity and routes to the appropriate provider. Also handles the `:elixir_native` route for queries that can be answered directly from ETS/Knowledge Graph without any LLM.

### Inference Pool

`Inference.Pool` provides back-pressure via a GenServer queue for when the OODA orchestrator is used with providers:
- Limits concurrent inference sessions
- Queues excess requests
- Timeout management (10-minute default)

---

## 9. Tools Layer

24 tools auto-discovered by `Tools.Registry` on boot. Each tool is a module implementing:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()
@callback execute(params :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
```

### Tool Inventory

| Category | Tool | Description |
|----------|------|-------------|
| **Read** | `read_file` | Sandboxed file reading |
| | `list_files` | Directory listing |
| | `get_function` | Extract function by name/arity |
| | `get_context` | Surrounding code context |
| | `get_module_info` | Module metadata from ETS |
| | `lookup_function` | Function details from index |
| | `search_code` | Pattern search across files |
| | `search_meaning` | Semantic search via embeddings |
| | `get_impact_map` | Blast radius from Knowledge Graph |
| | `trace_path` | Module dependency path |
| | `cycle_check` | Circular dependency detection |
| | `get_staged_files` | View transaction staging buffer |
| **Write** | `write_file` | Sandboxed file writing (stageable) |
| | `edit_file` | In-place editing with AST awareness (stageable) |
| | `write_function` | Insert new function into module (stageable) |
| | `patch_function` | Replace function body, preserve signature (stageable) |
| | `bulk_replace` | Mass pattern replacement across files |
| | `rename_mfa` | Cross-file module/function/arity rename |
| | `commit_changes` | Git commit staged transaction |
| **Control** | `think` | Model reasoning/planning (no side effects) |
| | `respond` | Final response to user (terminates loop) |
| | `run_mix` | Execute mix commands |
| | `run_tests` | Run mix test with path suggestions |

### StructuredOutput (JSON Guardrails)

Small models often produce malformed JSON. `StructuredOutput` and `StructuredOutput.Parser` handle:
- JSON extraction from chat preamble
- Markdown fence stripping
- Unclosed brace repair
- Multi-action parsing (model returns several tool calls)
- Hybrid format detection (action + code block)

---

## 10. Context Layer

### Context.Store (ETS)

The central data store. Holds all project state in ETS tables:

```elixir
# Storage patterns
{{:ast, "/path/to/file.ex"}, %{modules: [...], functions: [...], specs: [...], ...}}
{{:embeddings, "Giulia.Module"}, %Nx.Tensor{...}}
{:project_files, ["/path/to/file1.ex", ...]}
```

Provides 30+ query functions: `list_modules`, `list_functions`, `find_function`, `module_details`, `project_summary`, `list_specs`, `list_types`, `list_callbacks`, etc.

### Context.Indexer (GenServer)

Background AST scanner:
- Uses `Task.async_stream` for parallel file processing across all CPU cores
- Skips ignored directories (`node_modules`, `_build`, `deps`, `.git`, etc.)
- On completion: triggers Knowledge Graph rebuild and semantic embedding
- Status tracking: `idle` / `scanning`, file count, last scan time

### ProjectContext (Per-project GenServer)

Each active project gets its own GenServer managing:
- GIULIA.md constitution (loaded on init, reloaded on demand)
- Path sandbox (security boundary)
- Chat history
- Dirty file tracking
- Transaction mode preference
- Verification status

### PathSandbox (Security)

All file operations are validated against the sandbox:

```elixir
# Expands to absolute path, verifies containment under project root
PathSandbox.validate(sandbox, path)
# {:ok, expanded_path} or {:error, :sandbox_violation}
```

Prevents: `../../etc/passwd`, absolute paths outside project, symlink escapes. The model gets an error message, NOT the file contents.

### PathMapper (Host ↔ Container)

Translates paths between host and Docker container:

| Host Path | Container Path |
|-----------|----------------|
| `C:/Development/GitHub/Giulia` | `/projects/Giulia` |

Configured via `GIULIA_HOST_PROJECTS_PATH` env var. All API endpoints pass through PathMapper before touching the filesystem.

---

## 11. AST Layer

### AST.Processor (Sourceror — Pure Elixir)

27 public functions for code analysis and manipulation:

| Category | Functions |
|----------|-----------|
| **Parse** | `parse/1`, `parse_file/1` |
| **Analyze** | `analyze/2`, `analyze_file/1`, `summarize/1`, `detailed_summary/1`, `estimate_complexity/1` |
| **Extract** | `extract_functions/1`, `extract_modules/1`, `extract_specs/1`, `extract_types/1`, `extract_imports/1`, `extract_callbacks/1`, `extract_optional_callbacks/1`, `extract_docs/1`, `extract_moduledoc/1`, `extract_structs/1` |
| **Patch** | `patch_function/4`, `insert_function/3` |
| **Slice** | `slice_function/3`, `slice_function_with_deps/3`, `slice_around_line/3`, `slice_for_error/3`, `get_function_range/3` |

**Why Sourceror instead of Tree-sitter:**
- Pure Elixir, no C compiler needed
- Can parse AND write back code with formatting preserved
- Better for "father-killing" (Giulia improving her own code)
- Preserves `:end` metadata for accurate line ranges

**Known limitation** (discovered build 80): `get_function_range/3` line ranges can be inaccurate with Sourceror AST. For precise ranges, walk the function body AST nodes directly rather than relying on line range filtering.

---

## 12. HTTP API Surface

### Endpoint Groups

| Group | Prefix | Count | Purpose |
|-------|--------|-------|---------|
| Daemon | `/health`, `/api/status`, `/api/ping`, `/api/projects`, `/api/init` | 5 | Lifecycle management |
| Index | `/api/index/*` | 6 | ETS-backed AST queries |
| Knowledge | `/api/knowledge/*` | 18 | Graph topology analytics |
| Intelligence | `/api/intelligence/*`, `/api/briefing/*`, `/api/search/semantic*` | 4 | Pre-processing layers |
| Inference | `/api/command`, `/api/command/stream` | 2 | OODA orchestration |
| Approval | `/api/approval/*`, `/api/approvals` | 3 | Human-in-the-loop |
| Transaction | `/api/transaction/*` | 3 | Staging and rollback |
| Debug | `/api/debug/*`, `/api/agent/last_trace` | 2 | Inspection |
| Search | `/api/search` | 1 | Pattern search |

### SSE Streaming (`/api/command/stream`)

Real-time event stream via Server-Sent Events:

```
event: start         → {"request_id": "..."}
event: step          → {"type": "model_detected", "model": "qwen-14b", "tier": "medium"}
event: step          → {"type": "tool_call", "tool": "read_file", "params": {...}}
event: step          → {"type": "tool_result", "tool": "read_file", "result": "..."}
event: step          → {"type": "approval_required", "tool": "edit_file", ...}
event: step          → {"type": "baseline_warning", ...}
event: complete      → {"type": "complete", "response": "..."}
```

5-minute timeout. Events are broadcast via `Inference.Events` (pub/sub GenServer).

---

## 13. Security Model

### Path Sandbox

Every file operation goes through `PathSandbox.validate/2`:
- Expands to absolute path (resolves `..`, symlinks, relative paths)
- Verifies the expanded path starts with the project root
- `allowed_external` list for explicit exceptions

| Attack Vector | How Sandbox Blocks It |
|--------------|------------------------|
| `../../etc/passwd` | Expands outside project root |
| `/home/user/.ssh/config` | Absolute path outside sandbox |
| Symlink to `/` | `Path.expand` follows symlinks |
| Curious LLM | All tool operations go through sandbox |

### Constitution Enforcement

GIULIA.md defines per-project rules. Violations are intercepted before execution.

### Approval Gate

Writes to hub modules (high centrality) require human approval via the `/api/approval` endpoints. The orchestrator halts until the user responds.

### Transaction Isolation

Staged writes don't touch disk until verified. Failed compilations trigger automatic rollback.

---

## 14. Concurrency Model

### What Runs in Parallel

| Operation | Mechanism |
|-----------|-----------|
| File indexing | `Task.async_stream` across all CPU cores |
| Multiple projects | Separate `ProjectContext` GenServers |
| SSE streaming | Spawned process per request |
| Knowledge Graph build | Task spawned from Store GenServer |

### What Must Be Sequential

| Operation | Reason |
|-----------|--------|
| OODA loop steps | Each step depends on previous |
| Knowledge Graph queries | Serialized through Store GenServer |
| ETS writes | Atomic per key, ordered within a project |
| Provider calls | Rate-limited by API or local model |

---

## 15. Deployment

### Docker (Production)

```yaml
services:
  giulia:
    build: .
    container_name: giulia-daemon
    ports:
      - "4000:4000"
    volumes:
      - giulia_data:/data
      - ${GIULIA_PROJECTS_PATH:-./}:/projects
    environment:
      - GIULIA_HOME=/data
      - GIULIA_PORT=4000
      - GIULIA_HOST_PROJECTS_PATH=C:/Development/GitHub
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4000/health"]
```

### Native Binary (Burrito)

```bash
MIX_ENV=prod mix release giulia_client
# Output: burrito_out/giulia_{windows.exe,linux,macos,macos_arm}
```

### Environment Variables

**Core (required for daemon operation):**

| Variable | Purpose | Default |
|----------|---------|---------|
| `GIULIA_PORT` | HTTP API port | 4000 |
| `GIULIA_HOST_PROJECTS_PATH` | Host path prefix for path mapping | — |
| `GIULIA_HOME` | Data directory in container | `/data` |
| `GIULIA_IN_CONTAINER` | Running in Docker | auto-detected |
| `GIULIA_DAEMON_MODE` | Force daemon mode | false |
| `GIULIA_CLIENT_MODE` | Force client mode | false |

**Provider-specific (only if using OODA orchestrator with LLM providers):**

| Variable | Purpose | Default |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Anthropic provider | — |
| `GIULIA_LM_STUDIO_URL` | LM Studio base URL | `http://localhost:1234` |
| `GIULIA_LM_STUDIO_MODEL` | LM Studio model name | auto-detected |

---

## 16. Error Handling

### Supervision Strategy

```
Giulia.Supervisor (one_for_one)
├── Store crashes         → Restarts, ETS recreated, re-index triggered
├── Tools.Registry        → Restarts, re-discovers tools
├── Indexer crashes        → Restarts, re-scans project
├── Knowledge.Store       → Restarts, graph rebuilt from AST data
├── EmbeddingServing      → Returns :ignore if model unavailable (non-fatal)
├── SemanticIndex         → Degrades gracefully (search returns error)
├── Inference.Supervisor  → Pool + orchestrators restart
└── Bandit crashes        → HTTP server restarts
```

### Inference Error Recovery

```
Failure #1 → CORRECTION: error details sent back to model
Failure #2 → CORRECTION: valid options + error context
Failure #3 → INTERVENTION: clear message history, fresh AST summary, "start over"
Syntax ×2  → ESCALATION: cloud Senior Architect (Gemini/Groq) for surgical fix
Still stuck → DONE: return best-effort response with error summary
```

### Hallucination Prevention

- Unknown tool name → Available tools listed in correction
- Non-existent file → Similar paths suggested (Jaro distance)
- Repeated action → Force redirect to different approach
- Hub module write → Approval gate or transaction mode
- Behaviour violation → Integrity check blocks commit

---

## 17. Testing Strategy

### Test Tiers (Builds 87-88)

| Tier | Focus | Modules Covered |
|------|-------|----------------|
| Tier 1 | Foundation | AST.Processor, StructuredOutput, PathSandbox, PathMapper |
| Tier 2 | Context | Store, Indexer, Builder, ProjectContext |
| Tier 3 | Inference | State, Transaction, Verification, ResponseParser, ToolDispatch |
| Tier 4 | Integration | Provider, Router, Prompt.Builder, Pool, Orchestrator, Tools |

### Test Approach

- **Unit**: Pure function modules (State, Transaction, Analyzer) — no mocking needed
- **Integration**: GenServer modules (Store, Pool, Orchestrator) — start supervised
- **Property** (future): AST round-trip, JSON extraction, tool validation

---

## 18. Future Architecture

### Standalone Agent Mode

Activate the dormant provider layer to run Giulia as a fully autonomous agent — processing natural language tasks end-to-end with local or cloud LLMs, without requiring Claude Code. The OODA orchestrator, tool system, and transaction infrastructure are already implemented.

### Multi-Language Support (Sidecar)

```
┌─────────────────┐     ┌─────────────────┐
│     Giulia      │────▶│  Tree-sitter    │
│     (BEAM)      │◀────│  Sidecar (Rust) │
└─────────────────┘     └─────────────────┘
       Port/stdin-stdout
```

NIF crash = BEAM crash. Sidecar crash = Supervisor restarts Port.

### Speculative Parallel Fixes

```elixir
# When mix test fails, try N fixes in parallel
fixes
|> Task.async_stream(&apply_and_test/1)
|> Enum.find(&test_passed?/1)
```

Local model + fast tests = aggressive iteration.

### Distributed Mode (Daemon-to-Daemon)

```
┌─────────────────┐     ┌─────────────────┐
│   Giulia@work   │◀───▶│   Giulia@home   │
│   (Anthropic)   │     │    (Ollama)     │
└─────────────────┘     └─────────────────┘
       Erlang Distribution (daemon-to-daemon only)
```

ETS replication across nodes. Agent state migration.

---

*Last updated: Build 90 — February 2026*
