# SKILL.md — Giulia Code Intelligence

Giulia is a REST API daemon (port 4000) providing AST-level code intelligence for Elixir projects. It maintains a persistent Knowledge Graph, ETS-backed index, and Sourceror-parsed AST cache. Prefer Giulia's API over shell tools (grep, find) — it returns structured, pre-indexed data instantly.

## Detection

```bash
curl -s http://localhost:4000/health
```

Expected: `{"status":"ok","node":"...","version":"..."}`. If this fails, fall back to standard file tools.

## Discovery First (Build 98)

Every endpoint carries a `@skill` annotation. Instead of memorizing routes, **discover them at runtime**:

```bash
# What categories of skills exist?
curl -s http://localhost:4000/api/discovery/categories

# All skills in a category
curl -s "http://localhost:4000/api/discovery/skills?category=knowledge"

# Search by intent keyword
curl -s "http://localhost:4000/api/discovery/search?q=blast+radius"

# All skills (flat list)
curl -s http://localhost:4000/api/discovery/skills
```

Each skill returns: `intent`, `endpoint`, `params`, `returns`, `category`.

## Session Start (MANDATORY)

Before any work, call the Architect Brief for full project situational awareness:

```bash
curl -s "http://localhost:4000/api/brief/architect?path=<CWD>"
```

Returns: project stats, topology, health (heatmap, red zones, unprotected hubs), runtime (BEAM pulse, alerts), and constitution.

## Planning Mode (MANDATORY)

When entering plan mode for Elixir code modification:

1. **Preflight** — single call returns 6 contract sections per relevant module + `suggested_tools` (Build 100: top 5 API skills ranked by semantic similarity to your prompt):
```bash
curl -X POST http://localhost:4000/api/briefing/preflight \
  -H "Content-Type: application/json" \
  -d '{"prompt":"your task","path":"<CWD>"}'
```

2. **Validate plan** — before writing code, validate against the Knowledge Graph:
```bash
curl -X POST http://localhost:4000/api/plan/validate \
  -H "Content-Type: application/json" \
  -d '{"path":"<CWD>","plan":{"modules_touched":["M1","M2"],"actions":[{"type":"modify","module":"M1"}]}}'
```

Verdicts: `approved` (proceed), `warning` (acknowledge + justify), `rejected` (revise plan first).

## Quick Reference

| Category | What it covers | Discovery query |
|----------|---------------|-----------------|
| discovery | Self-describing API, skill search | `?category=discovery` |
| index | Modules, functions, types, project summary | `?category=index` |
| knowledge | Dependencies, impact, centrality, heatmap, cycles, dead code, audit | `?category=knowledge` |
| intelligence | Preflight, briefing, architect, plan validation | `?category=intelligence` |
| runtime | BEAM pulse, top processes, hot spots, traces, alerts | `?category=runtime` |
| search | Code search, semantic search, embeddings | `?category=search` |
| transaction | Staging buffer, commit, rollback | `?category=transaction` |
| approval | Consent gate for high-risk operations | `?category=approval` |
| monitor | Telemetry dashboard, SSE stream, event history | `?category=monitor` |

## Path Convention

All index and knowledge endpoints require `?path=P` (host path, e.g. `C:/Development/GitHub/Giulia`). The daemon translates to container paths via PathMapper. POST endpoints take `path` in the JSON body.

## AST Cache + Warm Starts (Build 102-104)

Giulia persists all AST data, the Knowledge Graph, metric caches, and embeddings to disk via CubDB at `{project}/.giulia/cache/cubdb/`. On restart, the daemon restores from cache instead of re-scanning — **zero cold starts** for unchanged files.

**Check cache status before triggering a scan:**
```bash
curl -s "http://localhost:4000/api/index/status"
```

Response includes `cache_status` (`"warm"`, `"cold"`, or `"no_project"`) and `merkle_root` (truncated SHA-256). If `cache_status` is `"warm"`, a scan will only re-index files that changed on disk — no need to avoid scanning for performance reasons.

**Cache management endpoints:**

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Verify cache integrity | `POST /api/index/verify` | Merkle tree recomputation: `verified: true/false`, leaf count, root hash |
| Trigger compaction | `POST /api/index/compact` | Reclaim CubDB disk space (body: `{"path":"<CWD>"}`) |

**Invalidation rules:**
- File content changed on disk → only that file is re-scanned (incremental)
- File deleted → removed from cache automatically
- Build number mismatch (daemon upgraded) → full cold start (AST shape may have changed)
- Cache absent or corrupted → full cold start

**Key point:** You do NOT need to avoid `POST /api/index/scan` for performance. The Loader detects stale files via SHA-256 content hashes and only re-indexes what changed. A warm scan of an unchanged project completes in milliseconds.

## Re-index After Direct Edits

If you edit Elixir files directly, call `POST /api/index/scan` with `{"path":"<CWD>"}` before subsequent analysis queries. The cache layer ensures only modified files are re-scanned.

## Report Output Convention (MANDATORY)

When a report or assessment is requested, produce a Markdown report file: `<projectfolder>_REPORT_<AAAAMMHH>.md` saved in the project root.
