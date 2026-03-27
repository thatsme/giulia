# Giulia

> **Build 154** · v0.2.1 · 2026-03-27

![Giulia Logic Monitor](docs/screenshot/giulia_monitor.jpg)

![Giulia Blast Radius](docs/screenshot/blast_radius.jpg)

Giulia is a high-performance, local-first AI development agent built in Elixir/OTP. It runs as a persistent background daemon with multi-project awareness, providing AST-level code intelligence, a Property Graph, runtime BEAM introspection, and semantic search -- all via a REST API.

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

- **CubDB warm starts**: AST entries, property graph, metric caches, and embeddings survive restarts. Merkle tree integrity verification detects stale files for incremental re-scanning.
- **ArcadeDB L2**: Multi-model graph database for cross-build history, consolidation queries, complexity drift detection, and coupling trend analysis.

## Quick Start

### Prerequisites

- Docker Desktop with Compose v2 plugin (`docker compose`, not `docker-compose`)
- Git

### Build and Start

```bash
git clone https://github.com/thatsme/giulia.git
cd giulia

# Build the Docker image
docker compose build

# Start worker (port 4000) + monitor (port 4001)
docker compose up -d

# Verify
curl http://localhost:4000/health
```

### First Scan

```bash
# Scan a project (use the host path -- Giulia translates it to the container path)
curl -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" \
  -d '{"path":"/path/to/your/project"}'

# Get the architect brief (full project awareness in one call)
curl "http://localhost:4000/api/brief/architect?path=/path/to/your/project"
```

## Architecture

```
Claude Code / CLI Client
         |
         | HTTP
         v
+------------------+     +-------------------+
| giulia-worker    |     | giulia-monitor    |
| :4000            |<--->| :4001             |
| Static analysis  |  ^  | Runtime profiling |
| Scans, graphs,   |  |  | Burst detection   |
| embeddings       |  |  | Performance data  |
+------------------+  |  +-------------------+
  |          |        |
  v          v        | Distributed Erlang
+------+  +-------+  |
| ETS  |  | CubDB |  +---> External BEAM apps
| (L1) |  | (warm |
|      |  | start)|
+------+  +-------+
              |
              v
         +-----------+
         | ArcadeDB  |
         | (L2)      |
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
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, OTP supervision tree, data flow |
| [API.md](API.md) | REST API reference (83 endpoints across 10 categories) |
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
- **Blast Radius**: Click any module to see depth-1/2 impact propagation
- **Hub Map**: Highlights high-degree modules

Supports force-directed, hierarchical, circle, and concentric layouts. Click any node for score, centrality, complexity, and test coverage details.

## Self-Analysis Demo

Giulia can analyze herself. The reports below were generated by pointing Giulia's API endpoints at her own codebase — the same analysis available for any Elixir project.

**[Giulia Self-Analysis Report (Build 146, PDF)](giulia_reports/Giulia_REPORT_2026032411.pdf)**

Highlights from the self-analysis:
- 143 modules, 1,471 functions, 1,614 graph vertices, 1,964 dependency edges
- 729 specs covering 79.9% of public functions, 0 dead code, 0 orphan specs
- 0 circular dependency cycles, 0 behaviour fractures
- Context.Store.Query has a 49-module blast radius (34% of codebase within 2 hops)
- 0 unprotected hubs — all high-fan-in modules have adequate spec coverage
- Runtime: 120 MB memory, 545 processes, 0 scheduler pressure

## Project Status

- **Build**: 154
- **Tests**: 1,732 tests
- **API**: 83 self-describing endpoints across 10 categories (core, discovery, index, knowledge, intelligence, runtime, search, transaction, approval, monitor)
- **Storage**: Three-tier (ETS L1 + CubDB warm start + ArcadeDB L2)
- **Containers**: Dual-container architecture (worker + monitor)
- **Visualization**: Logic Monitor (SSE) + Graph Explorer (Cytoscape.js)

## License

Copyright 2026 Alessio Battistutta

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
