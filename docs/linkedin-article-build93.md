# When Your AI Agent Can Feel the Machine Running — Builds 91-93

**How I gave Giulia runtime awareness, session memory, and the ability to reject bad plans.**

---

In my last post, I described Giulia — a persistent, AST-aware AI development agent built in Elixir that maintains a Knowledge Graph of your codebase. She knows which modules depend on which, where the complexity hotspots live, and what the blast radius looks like before you touch anything.

But she had a blind spot. Giulia could tell you everything about what your code *is*. She couldn't tell you what it's *doing*.

Builds 91 through 93 change that.

## The Cold Start Problem

Every AI coding session starts the same way. The assistant knows nothing about your project. You explain the architecture. You point it at the right files. You re-establish context that existed five minutes ago in a different terminal.

Build 91 eliminates this entirely.

### Build 91: The Architect Brief

One endpoint. One call. Everything an architect needs to understand the project.

```
GET /api/brief/architect?path=C:/Development/GitHub/MyApp
```

The response:

```json
{
  "project": { "files": 76, "modules": 76, "functions": 1016, "specs": 213 },
  "topology": {
    "vertices": 1089, "edges": 1326,
    "hubs": [{"module": "Tools.Registry", "degree": 30}, ...],
    "god_modules": [{"module": "Client", "score": 413, "complexity": 182}, ...]
  },
  "health": {
    "heatmap_summary": {"red": 7, "yellow": 50, "green": 16},
    "red_zones": [{"module": "Context.Store", "score": 78}, ...],
    "unprotected_hubs": {"count": 8},
    "integrity": "consistent"
  },
  "runtime": { ... },
  "constitution": { ... }
}
```

Project shape, dependency topology, health assessment, runtime status, and project rules — in a single HTTP call. The AI assistant fetches this at session start. No manual prompting. No "let me explore the codebase first." Session one and session one hundred start with the same level of understanding.

## From Dead Code to Live Code

Static analysis tells you what your code *is*. It reads the script. But it can't see the actors on stage.

Your Knowledge Graph says Module A depends on Module B. Useful. But is that dependency hot? Is A calling B 10,000 times per second, or is it a cold import that executes once at startup? Static analysis can't distinguish the two.

Build 92 gives Giulia a nervous system.

### Build 92: Runtime Proprioception

Giulia now harvests live data from running BEAM nodes using Distributed Erlang. No agents to install, no telemetry libraries to add. The BEAM already knows everything about its own processes — Giulia just asks the right questions.

**The Inspector** connects to any running BEAM node and reads:
- Process reductions (who's doing the most work)
- Memory allocation per process
- Message queue depths (who's choking)
- ETS table sizes (which tables are becoming "god tables")
- Current function per process (what is it doing *right now*)

**The Collector** runs a GenServer that snapshots this data every 30 seconds into an ETS ring buffer — 10 minutes of high-resolution temporal data. This enables questions that point-in-time metrics can't answer:

- "Knowledge.Store's message queue has been above 100 for 5 minutes"
- "Memory grew 40% in the last 10 minutes"
- "This module was the top CPU consumer in 18 of the last 20 snapshots"

But here's the real differentiator.

### PID-to-Module-to-Graph Fusion

When Giulia identifies a hot process, she doesn't stop at "PID <0.450.0> is using 60% of CPU." She resolves the PID to a module name, then looks up that module in the Knowledge Graph:

```json
{
  "module": "Knowledge.Store",
  "reductions_pct": 99.2,
  "memory_kb": 4972,
  "knowledge_graph": {
    "zone": "red",
    "complexity": 61,
    "in_degree": 13,
    "score": 70
  }
}
```

Static intelligence plus live telemetry equals actionable diagnosis. Not "something is slow" — but "*this specific red-zone module with 13 dependents is consuming 99% of CPU, and here's its complexity score.*"

This is the bridge between "what the code says" and "what the machine is doing." Most AI tools have one or the other. Giulia has both, fused.

### Eight New Endpoints

Build 92 ships 8 runtime endpoints: `pulse` (BEAM health), `top_processes` (sorted by metric), `hot_spots` (the fused view), `trace` (short-lived function-call frequency with a hard kill switch), `history` (Collector snapshots), `trend` (time-series per metric), `alerts` (with duration tracking), and `connect` (remote node authentication).

The trace deserves special mention. Tracing on a high-traffic BEAM node is surgery on a marathon runner. Without limits, you'll freeze the VM. Giulia's trace has non-negotiable hard limits: maximum 1,000 events or 5 seconds, whichever comes first. If it overflows, the trace self-terminates and returns partial results with an `aborted` flag. Safe by design.

## The Planning Gate

Now that Giulia knows both the structure and the runtime behavior of your code, the natural question is: can she prevent bad plans before any code is written?

### Build 93: Plan Validation Gate

Claude Code (or any AI assistant) sends a proposed plan — a list of modules to modify and what actions to take. Giulia validates it against the Knowledge Graph and returns a verdict.

```
POST /api/plan/validate
{"path": "...", "plan": {"modules_touched": ["Context.Store", "Knowledge.Store"]}}
```

Five checks run automatically:

1. **Cycle detection** — clones the dependency graph, adds the proposed edges, and checks for new circular dependencies. If your refactoring would create a cycle that doesn't exist today: **rejected**.

2. **Red zone collision** — counts how many red-zone modules (heatmap score >= 60) the plan touches. Two or more? **Warning**.

3. **Hub risk aggregation** — sums the centrality degrees of all touched modules. If the combined degree exceeds 40, you're modifying a lot of highly-connected code at once. **Warning**.

4. **Blast radius preview** — computes the union of all downstream dependents. Not a check, just information: "35 downstream modules affected."

5. **Unprotected hub write** — checks if the plan modifies hub modules that have low spec coverage. Modifying a module with 7 dependents and 0% type specs is a risk the AI should acknowledge.

The response includes a verdict, a risk score (0-100), and actionable recommendations:

```json
{
  "verdict": "warning",
  "risk_score": 79,
  "recommendations": [
    "Add @spec to Core.ProjectContext before modifying (0% coverage, 7 dependents)",
    "Consider splitting the plan: modify Store and Knowledge.Store in separate commits",
    "LIVE: Knowledge.Store is currently at 99.3% CPU — consider deferring modifications"
  ]
}
```

That last recommendation comes from Build 92's runtime data. The validator detected that one of the target modules is currently under heavy load. Static analysis alone would miss this entirely.

### The Enforcement Loop

A validation endpoint nobody calls is useless. The gate is enforced through Giulia's SKILL.md — the API reference that AI assistants read at session start:

> When formulating a multi-file refactor or any modification touching 2+ modules:
> 1. You MUST format your plan as JSON matching the `/api/plan/validate` schema
> 2. You MUST call the validation endpoint
> 3. If REJECTED, you are FORBIDDEN from writing code. Revise the plan.
> 4. If WARNING, acknowledge each warning and explain why you're proceeding

The brain (Claude) is gated by the exoskeleton (Giulia). The AI can't skip the check because the instruction is baked into the protocol it reads before starting work.

## The Numbers

|                          | Build 90  | Build 93  |
|--------------------------|-----------|-----------|
| Modules                  | 72        | 76        |
| Functions                | 1,007     | 1,016     |
| Knowledge Graph Vertices | 1,079     | 1,089     |
| Knowledge Graph Edges    | 1,309     | 1,326     |
| API Endpoints            | 44        | 54        |
| Tests                    | 660       | 660       |

Four new modules (`ArchitectBrief`, `Inspector`, `Collector`, `PlanValidator`), 10 new routes, 1,670 lines of new code. Zero blast radius on existing functionality — every new module is purely additive.

## Distributed Erlang: No Second Agent Needed

A question I got after describing the architecture: "Do you need two Giulia processes for runtime introspection?"

No. One Giulia daemon does everything. For self-introspection, it calls `:erlang.memory()` and `:erlang.processes()` directly. For remote nodes, it uses Distributed Erlang's `:rpc.call` — the same mechanism the BEAM uses natively for clustering.

The Docker daemon now starts with `--name giulia@0.0.0.0` and a configurable cookie. Connect any BEAM application by sharing the cookie and calling a single endpoint. Giulia scans the app's source code for static analysis, connects to its running node for live data, and fuses both in every query.

No sidecar. No agent library to install. No telemetry integration. Just the BEAM being the BEAM.

## What This Enables

With builds 91-93 complete, an AI assistant working with Giulia now has:

- **Session awareness** — full project topology from the first API call
- **Live telemetry** — "don't just tell me what the code says, tell me what the machine is doing"
- **Plan validation** — graph-aware pre-flight checks that prevent bad refactoring plans
- **Fused intelligence** — static analysis + runtime data in a single response

The next milestone (Build 94) merges both layers permanently: a runtime-weighted Knowledge Graph where edge weights reflect actual call frequency, enabling provable dead code detection (zero static callers AND zero runtime invocations) and traffic-filtered blast radius ("only 3 of the 30 dependents actually call this module at runtime").

---

*Giulia is a personal project built in Elixir on the BEAM. Builds 91-93 were implemented in a single session with Claude Code, using Giulia's own analysis endpoints to plan and validate each change. The builds were verified by the tool against its own codebase — 660 tests, 0 failures.*

*If you're working on AST-powered tooling, runtime-aware development agents, or the intersection of static analysis and live telemetry, I'd love to connect.*
