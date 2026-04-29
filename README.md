# Giulia

> **Build 161** · v0.3.8 · 2026-04-29 · **Status**: pre-1.0 — APIs may break between minor releases until v1.0.

![Giulia Logic Monitor](docs/screenshot/giulia_monitor.jpg)

![Giulia Blast Radius](docs/screenshot/blast_radius.jpg)

> **Giulia is the eyes, not the brain.** It analyzes your codebase and serves structured data over REST and MCP. Your LLM client — Claude Code, Claude Desktop, or anything that speaks REST or MCP — is the reasoner. Giulia never calls an LLM in production, never modifies your files, never runs autonomously. The only thing it writes to disk is its own cache (`.giulia/cache/`).
>
> *Legacy note*: a self-hosted local-chat inference layer (`POST /api/command`, internal LLM-provider tree) shipped in early v0.x and still loads, but is **deprecated as of v0.3.8** and will be removed in v0.4.0. The shipped product is the read-only data surface — see [ARCHITECTURE.md](ARCHITECTURE.md) Section 18.

Giulia is a persistent, local-first code intelligence daemon built in Elixir/OTP. It runs as a long-lived background process with multi-project awareness, providing AST-level code intelligence, a Property Graph, runtime BEAM introspection, and semantic search -- via both a REST API and native MCP (Model Context Protocol) integration.

## Who is this for?

Solo Elixir developers and consultants working on real-world Phoenix / OTP codebases who want their AI assistant to keep context across sessions instead of cold-starting every time. **Single-user, single-host** today — no team auth, no multi-user model beyond the MCP bearer token. If you're driving Claude Code (or any MCP/REST-capable client) against a 50k+ LOC Elixir project, this is for you.

## Why Giulia Exists

AI coding assistants restart from zero every session. They lose context, re-index files, and grep for everything on every interaction. Giulia solves this by running as a long-lived daemon on the BEAM VM:

- **Warm state**: AST indexes, Property Graphs, and embeddings stay in ETS between sessions.
- **Multi-project**: Switch terminals and projects instantly -- each gets its own isolated context.
- **No cold starts**: CubDB persistence restores full state on restart without re-scanning.
- **Deep analysis**: Dependency graphs, blast radius, coupling metrics, and dead code detection -- precomputed and cached, not computed on every query.

## What It Does

### Static Analysis (L1 -- ETS + libgraph)

Sub-millisecond queries over the full project graph. Modules, functions, dependencies, centrality, impact maps, coupling heatmaps, complexity scores. All built from Sourceror AST parsing with parallel file scanning.

### Runtime Introspection

Connect to any running BEAM node via distributed Erlang. Inspect memory, top processes, hot modules, and fuse runtime data with static analysis for performance profiling. Worker and monitor containers operate as a two-node cluster.

### Persistent Intelligence

- **CubDB warm starts (L2)**: AST entries, property graph, metric caches, and embeddings survive restarts. Merkle tree integrity verification detects stale files for incremental re-scanning.
- **ArcadeDB (L3)**: Multi-model graph database for cross-build history, consolidation queries, complexity drift detection, and coupling trend analysis.

### External Tool Enrichment

Giulia ingests output from existing Elixir tools — **Credo and Dialyzer ship today**; ExUnit coverage / ExDoc / Sobelow share the same scaffolding — and attaches each finding to the corresponding function or module vertex in the knowledge graph. `pre_impact_check` and `dead_code` then surface "47 callers, blast radius wide, AND this function has 2 outstanding type warnings" instead of either signal in isolation. Pluggable behaviour (`Giulia.Enrichment.Source`) + JSON registry (`priv/config/enrichment_sources.json`) with per-tool severity maps — adding a new tool is one parser module + one JSON entry. Tool findings live in their own CubDB keyspace and are preserved across source rescans (CI cadence is decoupled from extractor cadence).

## Quick Start

### Prerequisites

- Docker Desktop with Compose v2 plugin (`docker compose`, not `docker-compose`)
- Git
- ~7 GB RAM available for containers (worker 4 GB + monitor 2 GB + ArcadeDB ~512 MB). Actual peak depends on codebase size — a 50 k-LOC project comfortably fits; larger codebases may push the worker limit and warrant raising it in `docker-compose.yml`.

### Build and Start

```bash
git clone https://github.com/thatsme/giulia.git
cd giulia

# Build the Docker image
docker compose build

# Start worker (port 4000) + monitor (port 4001).
# GIULIA_HOST_PROJECTS_PATH tells Giulia where on the host to find your code;
# it's translated to /projects inside the container. Default points at the
# parent of the current dir — adjust if your projects live elsewhere.
GIULIA_HOST_PROJECTS_PATH="$(dirname "$(pwd)")" docker compose up -d

# Verify
curl http://localhost:4000/health
```

If a scan returns "path not found" errors, the host-to-container translation is wrong — see [INSTALLATION.md](INSTALLATION.md) for `GIULIA_HOST_PROJECTS_PATH` setup.

### First Scan

```bash
# Scan a project (use the host path -- Giulia translates it to the container path)
curl -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" \
  -d '{"path":"/path/to/your/project"}'

# Get the architect brief (full project awareness in one call)
curl "http://localhost:4000/api/brief/architect?path=/path/to/your/project"
```

### Wire to your LLM client (MCP)

Add Giulia as an MCP server in your client config (`.mcp.json`):

```json
{
  "mcpServers": {
    "giulia": {
      "type": "http",
      "url": "http://localhost:4000/mcp",
      "headers": {
        "Authorization": "Bearer <GIULIA_MCP_KEY value>"
      }
    }
  }
}
```

Set `GIULIA_MCP_KEY` in your env / compose before starting; the MCP server only loads if it's set. Once wired, your LLM client sees 71 tools — every read-only Giulia endpoint becomes a tool call without HTTP plumbing.

## Architecture

```
Claude Code / CLI Client
         |
         | HTTP (REST) or MCP
         v
+------------------+     +-------------------+
| giulia-worker    |     | giulia-monitor    |
| :4000            |<--->| :4001             |
| Static analysis  |  ^  | Runtime profiling |
| Scans, graphs,   |  |  | Burst detection   |
| embeddings       |  |  | Performance data  |
| MCP server       |  |  |                   |
+------------------+  |  +-------------------+
  |          |        |
  v          v        | Distributed Erlang
+------+  +-------+  |
| ETS  |  | CubDB |  +---> External BEAM apps
| (L1) |  | (L2,  |
|      |  |  warm |
|      |  |  start|
+------+  +-------+
              |
              v
         +-----------+
         | ArcadeDB  |
         | (L3)      |
         | :2480     |
         | History,  |
         | trends,   |
         | cross-    |
         | build     |
         +-----------+
```

## Documentation

| Document | Description |
|---|---|
| [INSTALLATION.md](INSTALLATION.md) | Prerequisites, setup, configuration, troubleshooting |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, OTP supervision tree, data flow, 11 graph-builder passes |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Per-variable reference for `priv/config/*.json` (scoring, dispatch patterns, scan roots, dispatch invariants, relevance buckets) and the cache-invalidation contract |
| [API.md](API.md) | REST API and MCP reference (85 endpoints across 10 categories) |
| [docs/REPORT_RULES.md](docs/REPORT_RULES.md) | Standard report-generation procedure for AI agents and humans |
| [TESTING.md](TESTING.md) | Test environment setup, running tests, conventions |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development workflow, build counter rules, PR process |
| [CODING_CONVENTIONS.md](CODING_CONVENTIONS.md) | Code style, patterns, naming conventions |
| [SECURITY.md](SECURITY.md) | Path sandboxing, constitution enforcement, threat model |

## Visual Dashboards

### Logic Monitor (`/api/monitor`)

Real-time cognitive flight recorder. Every REST call, inference step, LLM call, and tool execution streams via SSE. Project-scoped filtering lets you isolate events per codebase when analyzing multiple projects.

### Graph Explorer (`/api/monitor/graph`)

Interactive dependency graph visualization powered by Cytoscape.js. Four views:
- **Dependency Graph**: Full module topology, nodes colored by heatmap zone (red/yellow/green), sized by centrality
- **Heatmap**: Emphasizes risky modules, dims healthy ones
- **Blast Radius**: Click any module to see depth-1/2 impact propagation (the second screenshot above shows this view)
- **Hub Map**: Highlights high-degree modules

Supports force-directed, hierarchical, circle, and concentric layouts. Click any node for score, centrality, complexity, and test coverage details.

## Self-Analysis Demo

Giulia can analyze herself. The report below was generated by pointing Giulia's API endpoints at her own codebase — the same analysis available for any Elixir project.

**[Giulia Self-Analysis — Build 146 snapshot, PDF](giulia_reports/Giulia_REPORT_2026032411.pdf)** *(early April 2026; regenerate against current HEAD for an up-to-date view — the README header build / version above is the current code, not the report.)*

Highlights from the Build 146 snapshot:
- 143 modules, 1,471 functions, 1,614 graph vertices, 1,964 dependency edges
- 729 specs covering 79.9% of public functions, 0 dead code, 0 orphan specs
- 0 circular dependency cycles, 0 behaviour fractures
- Context.Store.Query has a 49-module blast radius (34% of codebase within 2 hops)
- 0 unprotected hubs — all high-fan-in modules have adequate spec coverage
- Runtime: 120 MB memory, 545 processes, 0 scheduler pressure

## Project Status

### Status

- **Version**: v0.3.8 (Build 161)
- **Stability**: pre-1.0 — API contracts may break between minor releases until v1.0.
- **Tests**: 1000+ unit/integration tests across `ast/`, `knowledge/`, `persistence/`, `context/`, `tools/`, `enrichment/` subsets, plus 13 StreamData property tests and 7 golden-fixture tests for extraction output.

### Capabilities

- **API**: 85 self-describing endpoints across 10 categories (core, discovery, index, knowledge, intelligence, runtime, search, transaction, approval, monitor)
- **MCP**: native server exposing 71 tools + 5 resource templates, bearer-token auth
- **Storage**: three-tier (ETS L1 + CubDB L2 + ArcadeDB L3) with startup warm-restore from L2 so `/api/projects` stays populated across `docker compose restart`. L2 cache auto-invalidates on code-tier or config-file edits via the CodeDigest envelope.
- **Containers**: dual-container (worker + monitor)
- **Visualization**: Logic Monitor (SSE) + Graph Explorer (Cytoscape.js)

### Design commitments

- **Graph synthesis**: 11 builder passes from AST to graph. Passes 7-11 synthesize edges for runtime-dispatched call sites the static walker can't resolve directly (defprotocol/defimpl, behaviour callbacks, Phoenix router actions, MFA tuples, `&` captures, `apply/3`, `Task.start_link(M, F, A)` form, and unqualified calls resolved through `use M`-injected imports). Universal mechanisms — no project-specific allowlists.
- **Cross-store invariants**: `GET /api/knowledge/verify_l2` and `verify_l3` endpoints run on every mix-test invocation, with drift-detection tests that tamper L2/L3 state and assert the verifier catches the mismatch.
- **Dead-code categorization**: every `dead_code` entry classified (`genuine | test_only | library_public_api | template_pending | uncategorized`) so consumers see actionable vs irreducible residuals at a glance.
- **External tool enrichment**: pluggable ingestion of Credo and Dialyzer output (47-warning catalogue covered) attached to graph vertices and surfaced inline in `pre_impact_check` and `dead_code`. Decoupled from source-extraction lifecycle.

### Configuration surface

Tunable behaviour lives in JSON, edited and reloaded via daemon restart (no recompile). All edits trigger automatic L2 metric-cache invalidation via the CodeDigest envelope (see [docs/CONFIGURATION.md](docs/CONFIGURATION.md)).

- [`priv/config/scoring.json`](priv/config/scoring.json) — heatmap and change_risk scoring constants
- [`priv/config/dispatch_patterns.json`](priv/config/dispatch_patterns.json) — runtime-dispatch patterns the AST walker can't see
- [`priv/config/scan_defaults.json`](priv/config/scan_defaults.json) — source roots + ArcadeDB history retention
- [`priv/config/enrichment_sources.json`](priv/config/enrichment_sources.json) — enrichment source registry + per-tool severity maps
- [`priv/config/dispatch_invariants.json`](priv/config/dispatch_invariants.json) — project-root markers, OTP/framework implicit functions, known-behaviour callback signatures, Phoenix HTTP verbs *(v0.3.8+)*
- [`priv/config/relevance.json`](priv/config/relevance.json) — bucket boundaries for `?relevance=high|medium|all` on `dead_code` / `conventions` / `duplicates` *(v0.3.8+)*

### Deprecated — will be removed in v0.4.0

The early-v0.x local-chat inference layer (Giulia ran an internal Observe-Orient-Decide-Act loop calling LM Studio / Anthropic / etc., dispatching write-tools behind interactive approval gates):

- `Giulia.Inference.*` (32 modules), `Giulia.Provider.*` (6 LLM providers)
- HTTP endpoints `POST /api/command`, `POST /api/command/stream`, `/api/approval/*`, `/api/transaction/*`
- MCP tools under `approval_*` / `transaction_*` prefixes
- Write-tools `patch_function`, `bulk_replace`, `rename_mfa`
- Compose env vars `LM_STUDIO_URL`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY`

Canonical LLM integration is now external clients (Claude Code, Claude Desktop, etc.) calling Giulia over REST or MCP. See [ARCHITECTURE.md](ARCHITECTURE.md) Section 18 for the full deprecation set.

## License

Copyright 2026 Alessio Battistutta

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
