# Building an AI Agent That Understands Code at the AST Level — in Elixir

**Why I'm building Giulia, a local-first AI development agent on the BEAM, and how Claude Code became part of the workflow.**

---

Every AI coding assistant today works the same way: read your prompt, grep some files, generate a response, forget everything. The next session starts from zero. Your project's architecture, dependency graph, module coupling — gone. You re-explain the same context every single time.

I decided to build something different.

## The Problem with Stateless Agents

Current AI coding tools treat your codebase as flat text. They search with regex, guess at relationships, and have no memory of what they analyzed five minutes ago. Ask "what depends on this module?" and the tool runs `grep`, returning noisy results that miss indirect dependencies entirely.

This is the fundamental issue: **text search is not code understanding.**

A codebase has structure — modules depend on other modules, functions call other functions, behaviours define contracts. This structure is already encoded in the AST (Abstract Syntax Tree). Why are we throwing it away?

## Giulia: A Persistent, AST-Aware Agent

Giulia is an AI development agent built in Elixir that runs as a **persistent background daemon**. She doesn't start fresh every session. She maintains:

- A **Knowledge Graph** built from AST analysis — 1,079 vertices, 1,309 edges for her own codebase
- **Per-project state** in GenServers and ETS, not in chat history
- A **sandboxed tool system** where every file operation is validated against a security boundary
- An **OODA inference loop** (Observe-Orient-Decide-Act) with approval gates for dangerous operations

When I ask "what's the blast radius of changing this module?", Giulia doesn't grep. She queries her pre-indexed dependency graph and returns the answer in milliseconds — upstream dependencies, downstream dependents, hub score, coupling metrics. All from the live AST.

### Why Elixir and the BEAM?

This wasn't an arbitrary language choice. The BEAM VM gives Giulia properties that would require significant infrastructure in other languages:

- **GenServers for project state**: Each project gets its own supervised process. AST cache, dirty file tracking, conversation history — all in-memory, fault-tolerant. If a project context crashes, the supervisor restarts it. No data loss.
- **ETS for the index**: Sub-microsecond lookups for module metadata, function signatures, type specs. No external database needed.

### The Architecture

```

Terminal A: ~/project-alpha    Terminal B: ~/project-beta
    |                               |
    v                               v
+--------------------------------------------------------+
|                   GIULIA DAEMON (BEAM)                 |
|                                                        |
|  ProjectContext(alpha)       ProjectContext(beta)      |
|  - AST cached                - AST cached              |
|  - Knowledge Graph           - Knowledge Graph         |
|  - Constitution loaded       - Constitution loaded     |
+--------------------------------------------------------+
                   Bandit HTTP API on :4000

```

The daemon-client split is deliberate. The daemon holds warm state — AST caches, the knowledge graph, loaded LLM models. The client is a thin HTTP wrapper. Open a new terminal, type a command, and you're talking to the same daemon with full context. No cold starts.

### The Knowledge Graph

This is the core differentiator. Giulia builds a directed graph from four analysis passes:

1. **Module dependencies** — `alias`, `import`, `use`, `@behaviour` directives
2. **Struct references** — which modules construct or pattern-match on which structs
3. **Behaviour contracts** — `@callback` declarations and their implementers
4. **Function-level edges** — xref + AST-based call extraction for MFA (Module.Function.Arity) precision

The result: instant answers to questions that would take minutes of manual investigation.

- `GET /api/knowledge/dependents?module=X` — Who breaks if I change X?
- `GET /api/knowledge/impact?module=X&depth=2` — Full upstream + downstream at depth N
- `GET /api/knowledge/heatmap` — Composite health score per module (complexity + centrality + coupling)
- `POST /api/knowledge/pre_impact_check` — Risk analysis for rename/remove operations
- `GET /api/knowledge/audit` — Unified report combining unprotected hubs, struct lifecycle, semantic duplicates, and behaviour integrity in one call

The heatmap alone changed how I prioritize refactoring. At build 90, Giulia's own codebase has 7 red-zone modules, 49 yellow, and 16 green. The unified audit reveals 8 unprotected hub modules (high centrality, low spec coverage), tracks data flow across 6 structs, and confirms all behaviour contracts are consistent with zero fractures. I can see exactly where the technical debt lives and how dangerous each module is to touch.

### Transactional Safety

File modifications go through a transactional staging buffer with compile-check-before-commit. If compilation fails, everything rolls back — including a forced BEAM recompile to prevent ghost modules. Hub modules (3+ dependents) auto-enable staging, so the agent can't accidentally break high-centrality code without an explicit commit step.

## The Claude Code Symbiosis

Here's where it gets interesting. Giulia's daemon exposes her entire analysis API over HTTP. This means **any tool** can query her — including Claude Code.

My workflow today: Claude Code reads Giulia's SKILL.md (the API reference), checks the daemon health, then queries impact analysis and centrality before planning any code modification. The global CLAUDE.md enforces this:

> *"No plan is valid without blast radius data."*

The result is a feedback loop: Claude Code uses Giulia's knowledge graph to understand the codebase, then writes the code that makes Giulia smarter. Giulia's own test suite (660 tests across 4 tiers) was largely written through this workflow. Build 84's Orchestrator decomposition — shrinking it from 3,312 lines to 203 — was planned using Giulia's heatmap data and executed with Claude Code.

This isn't AI replacing the developer. It's **layered intelligence**: a persistent, specialized agent (Giulia) providing structural knowledge to a general-purpose agent (Claude Code), with a human architect making the decisions.

## Current State: Build 90

|--------------------------|-----------------------|
| Metric                   | Value                 |
|--------------------------|-----------------------|
| Modules                  | 72                    |
| Functions                | 1,007                 |
| Type Specs               | 212                   |
| Knowledge Graph Vertices | 1,079                 |
| Knowledge Graph Edges    | 1,309                 |
| Test Suite               | 660 tests, 0 failures |
| Providers                | LM Studio, Anthropic, |
|                          | Ollama, Gemini, Groq  |
| Tools                    | 22 registered         |
| API Endpoints            | 44                    |
|--------------------------|-----------------------|

The red-zone refactoring over builds 81-84 extracted 6 modules from the two worst offenders (Orchestrator and Knowledge.Store), reducing the largest module by 94%.

Builds 85-90 then added a comprehensive test suite (660 tests across 4 tiers), a Principal Consultant analysis layer (unprotected hub detection, struct lifecycle tracing, behaviour integrity with 4-level classification), and operational semantic search powered by on-device embeddings.

### Semantic Search — On-Device, Sub-300ms

Giulia runs **all-MiniLM-L6-v2** locally via Bumblebee + EXLA. Every function in the codebase gets embedded and indexed. Search is two-phase: a fast cosine similarity pass narrows candidates, then AST-aware reranking surfaces the most relevant results. Query-to-answer in under 300ms, entirely on-device. No API calls, no data leaving the machine.

This powers the `style_oracle` endpoint — ask "how should I write a GenServer callback?" and Giulia returns exemplar functions from your own codebase, quality-gated (must have both `@spec` and `@doc`). Your project's conventions, not generic advice.

## What's Next

Giulia is a personal project — built evenings and weekends, one build at a time. The immediate roadmap:

- **AST.Processor decomposition** (Reader/Writer/Metrics split — complexity 164, the second-worst red module)
- **Endpoint router extraction** (pluggable sub-routers for knowledge, index, transaction APIs)
- **Spec coverage hardening** — the audit identified 8 hub modules with less than 50% spec coverage, a type safety gap in the most depended-on code
- **Self-improvement loops** — using Giulia's own analysis to plan and execute her next refactoring, with the human architect approving each step

### Beyond Giulia's Own Codebase

Giulia has analyzed external codebases including a 66-module CQRS/ES framework and a 142-module autonomous agent framework, producing full architectural assessments with heatmaps, change risk rankings, and behaviour contract validation. Same endpoints, same sub-second response times — on code she's never seen before.

The long-term vision: a development agent that knows your codebase as well as you do — and never forgets.

---

*Giulia is a personal project built in Elixir on the BEAM. If you're interested in AST-powered code intelligence, persistent agents, or the intersection of LLMs and static analysis, I'd love to hear from you.*

*The entire project — including this article's data — was analyzed by the tool itself.*
