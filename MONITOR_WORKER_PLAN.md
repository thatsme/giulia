# Monitor/Worker Architecture — Implementation Plan

## Goal

Enable Giulia to analyze **herself** with surgical precision. Two containers from the same image:

- **giulia-worker** (port 4000) — does heavy work (scans projectX, builds graphs, embeddings)
- **giulia-monitor** (port 4001) — does static + runtime analysis of **Giulia's own code** running inside the worker

ProjectX is just a treadmill. We don't care about its analysis results. We care about
how Giulia behaves while doing the work — which of her own modules are CPU bottlenecks,
where memory spikes, which functions are hot AND have high cognitive complexity.

## User Workflow

```
~/projectX/    → claude code → giulia-worker (:4000)   "scan this project"
~/Giulia/      → browser/curl → giulia-monitor (:4001)  "show me what the worker is doing"
```

The worker is unaware of the monitor. The monitor is passive — connects via distributed
Erlang, polls the worker's BEAM counters, and fuses runtime data with static analysis
of Giulia's own source code.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        docker-compose                                │
│                                                                      │
│  ┌─────────────────────┐              ┌─────────────────────┐       │
│  │  giulia-monitor     │   erlang     │  giulia-worker      │       │
│  │  :4001              │──  dist  ───>│  :4000              │       │
│  │                     │   (read      │                     │       │
│  │  Static analysis:   │    only)     │  Static analysis:   │       │
│  │  Giulia's own code  │              │  projectX's code    │       │
│  │                     │              │                     │       │
│  │  Runtime analysis:  │              │  Heavy work:        │       │
│  │  Worker's BEAM VM   │              │  AST scan, graph,   │       │
│  │  (pulse, processes, │              │  embeddings, metrics│       │
│  │   hot spots, trace) │              │                     │       │
│  │                     │              │                     │       │
│  │  Fusion:            │              │                     │       │
│  │  Worker hot PIDs    │              │                     │       │
│  │  → Giulia modules   │              │                     │       │
│  │  → Giulia KG data   │              │                     │       │
│  │  → Cognitive scores  │              │                     │       │
│  └─────────────────────┘              └─────────────────────┘       │
│         │                                      │                     │
│         │ /projects/Giulia (source, read-only)  │ /projects (all)    │
│         └──────────────────────────────────────-┘                    │
└──────────────────────────────────────────────────────────────────────┘
```

## Monitor State Machine

The monitor doesn't just poll continuously — it detects when the worker is under
real load and captures data during the burst.

```
                    ┌──────────────────────────────────┐
                    │                                    │
                    ▼                                    │
              ┌──────────┐   reductions/s spike    ┌────┴──────┐
  boot ──────>│   IDLE   │ ─────────────────────> │ CAPTURING │
              │ poll 5s  │                         │ sample    │
              └──────────┘                         │ 500ms     │
                    ▲                              └────┬──────┘
                    │                                    │
              ┌─────┴──────┐   activity drops            │
              │  PROFILING  │ <─────────────────────────┘
              │ fuse static │
              │ + runtime   │
              │ save report │
              └─────────────┘
```

- **IDLE**: Poll worker pulse every 5 seconds. Low overhead.
- **CAPTURING**: Reductions/s or process count jumped above threshold. Switch to
  500ms sampling — capture pulse + top_processes every half second.
- **PROFILING**: Activity dropped back to baseline. Stop capturing. Fuse the
  collected runtime snapshots with Giulia's own Knowledge Graph. Produce a
  performance profile and save it.

## Current State (what already exists)

| Component | Status | Notes |
|---|---|---|
| Runtime endpoints with `?node=` param | Done | All 8 endpoints accept remote node |
| `Inspector.connect/2` | Done | One-shot connection, no reconnect |
| `Inspector.pulse/1` with RPC | Done | 5s timeout, works remote |
| `Inspector.top_processes/2` with RPC | Done | Works remote |
| `Inspector.hot_spots/2` with fusion | Done | Fuses PIDs with local KG — needs local KG of Giulia |
| `Collector` GenServer | Done | Polls one node, stores in ETS ring buffer |
| Telemetry events (Build 95) | Done | 7 events across OODA pipeline |
| Monitor SSE dashboard (Build 95-96) | Done | Live event stream |
| Docker compose | Partial | Single service, hardcoded node name |
| Node name configurability | Missing | `giulia@0.0.0.0` hardcoded in docker-compose |
| Auto-connect on startup | Missing | Connection is manual POST |
| Collector multi-node | Missing | Watches single node set at init |
| Burst detection + high-freq sampling | Missing | Collector uses fixed 60s interval |
| Profile generation | Missing | No post-burst report |

## Implementation Plan

### Build 131: Core Infrastructure + Role Gating

Five changes that ship together — without any one of them, the feature doesn't work.

#### 1. Role Module (promoted from Build 133 — must gate supervision tree from day one)

**New file**: `lib/giulia/role.ex`

```elixir
def role(), do: System.get_env("GIULIA_ROLE", "standalone") |> String.to_atom()
def monitor?(), do: role() == :monitor
def worker?(), do: role() == :worker
def standalone?(), do: role() == :standalone
```

**Why promoted**: EmbeddingServing loads a ~90MB transformer model into RAM on startup.
If the monitor container has a 1G soft limit, that's 9% burned on something it never uses.
Starting it only to kill it later risks OOM before role filtering kicks in. Gate from day one.

**Modify**: `lib/giulia/application.ex`

Monitor mode skips heavy children:
- `Giulia.Intelligence.EmbeddingServing` (embeddings are worker's job)
- `Giulia.Inference.Supervisor` (LLM inference is worker's job)
- `Giulia.Inference.Pool` (provider connection pools)

Worker and standalone modes start the full tree (current behavior, zero changes).

#### 2. Configurable Node Name

**File**: `docker-compose.yml`

Change the command to use `GIULIA_NODE_NAME` env var:

```yaml
command: >-
  /bin/sh -c "cd /app && mix deps.get &&
  elixir --name ${GIULIA_NODE_NAME:-giulia@0.0.0.0}
  --cookie ${GIULIA_COOKIE:-giulia_dev}
  --erl '-kernel inet_dist_listen_min ${GIULIA_DIST_PORT_MIN:-9100}
         inet_dist_listen_max ${GIULIA_DIST_PORT_MAX:-9105}'
  -S mix run --no-halt"
```

No Elixir code changes. Node name is set by `elixir --name` before the BEAM starts.

#### 3. Auto-Connect GenServer

**New file**: `lib/giulia/runtime/auto_connect.ex`

GenServer that:
- Reads `GIULIA_CONNECT_NODE` env var (e.g., `worker@giulia-worker`)
- If unset, returns `:ignore` from `init/1` (no-op for standalone/worker mode)
- On init, schedules retry loop with exponential backoff (5s -> 10s -> 20s -> cap 60s)
- On successful connection, calls `Collector.watch_node/1` to start monitoring
- Exposes `connected?/0` and `target_node/0` for other modules

**OTP note**: Child spec uses `{AutoConnect, []}` tuple form. When `init/1` returns
`:ignore`, the supervisor silently drops the child from the tree. This is standard OTP
behavior — no special handling needed. Standalone and worker modes are completely unaffected.

**Modify**: `lib/giulia/application.ex`

Add `{Giulia.Runtime.AutoConnect, []}` to supervision tree after `Giulia.Runtime.Collector`.

#### 4. Collector Multi-Node + Burst Detection

**Modify**: `lib/giulia/runtime/collector.ex`

Current state: single node, fixed 60s interval, 20-entry buffer.

Changes:
- `state.node` -> `state.nodes` (list of atoms, default `[:local]`)
- New public `watch_node/1` — casts `{:watch_node, node_atom}`, appends to list
- New state field: `state.mode` — `:idle | :capturing`
- New state field: `state.baseline` — reductions/s from last idle sample
- New configurable: `state.idle_interval` (5_000ms) and `state.capture_interval` (500ms)

Burst detection logic in `handle_info(:collect)`:
- Calculate reductions delta since last sample
- If reductions/s > 3x baseline -> switch to `:capturing` mode, reduce interval to 500ms
- If in `:capturing` and reductions/s drops below 1.5x baseline for 3 consecutive samples
  -> switch to `:profiling`, emit `{:profile_ready, node, snapshots}` to a callback

Buffer size increase: 600 entries (at 500ms capture = 5 minutes of burst data).

#### 5. Docker Compose Dual Service

**Modify**: `docker-compose.yml`

Two services from the same image:

```yaml
services:
  giulia-worker:
    image: giulia/core:latest
    build: { context: ., dockerfile: Dockerfile }
    container_name: giulia-worker
    hostname: giulia-worker
    environment:
      GIULIA_NODE_NAME: worker@giulia-worker
      GIULIA_ROLE: worker
      GIULIA_PORT: "4000"
      GIULIA_DIST_PORT_MIN: "9100"
      GIULIA_DIST_PORT_MAX: "9105"
      # ... all existing env vars
    ports:
      - "4000:4000"
      - "4369:4369"
      - "9100-9105:9100-9105"
    volumes: # same as current
    # ... resource limits, healthcheck, restart policy

  giulia-monitor:
    image: giulia/core:latest
    container_name: giulia-monitor
    hostname: giulia-monitor
    depends_on:
      giulia-worker:
        condition: service_healthy
    environment:
      GIULIA_NODE_NAME: monitor@giulia-monitor
      GIULIA_ROLE: monitor
      GIULIA_PORT: "4001"
      GIULIA_CONNECT_NODE: worker@giulia-worker
      GIULIA_DIST_PORT_MIN: "9110"
      GIULIA_DIST_PORT_MAX: "9115"
      # ... same API keys, path mapping, etc.
    ports:
      - "4001:4001"
      # EPMD host port note: 4370:4369 is only for host-side access
      # (e.g., connecting from a BEAM on the Windows host). Container-to-
      # container communication goes through Docker's internal network
      # where both containers listen on 4369 in their own network namespace.
      # No conflict there — they're separate namespaces. The host port
      # remapping avoids collision only on the host's loopback.
      - "4370:4369"
      - "9110-9115:9110-9115"
    volumes: # same mounts — both read /projects/Giulia
```

Key points:
- Docker DNS resolves `giulia-worker` to the worker container's IP
- Container-to-container: EPMD on 4369 inside each namespace, no conflict
- Host-side: 4369 (worker) vs 4370 (monitor) to avoid loopback collision
- `depends_on: service_healthy` ensures worker is up before monitor starts
- Same shared volume — monitor scans Giulia's source from `/projects/Giulia`

---

### Build 132: Monitor Lifecycle + Profiling

#### 6. Monitor Boot Sequence

**New file**: `lib/giulia/runtime/monitor.ex`

GenServer that orchestrates the monitor's lifecycle:

1. **BOOT**: Trigger scan of Giulia's own source code
   - Call `Giulia.Context.Indexer.scan("/projects/Giulia")`
   - **Non-blocking poll**: Use `Process.send_after(self(), :check_scan, 500)` in a
     `handle_info(:check_scan)` loop — NOT a blocking receive or busy-wait.
     The GenServer must stay responsive to `:stop`, `:status`, or other messages
     during the potentially long initial scan.
   - On `Indexer.status().status == :idle` -> transition to CONNECT phase
   - Knowledge Graph of Giulia's modules is now in ETS

2. **CONNECT**: Wait for `AutoConnect` to establish distributed Erlang
   - Same pattern: `Process.send_after(self(), :check_connect, 1_000)`
   - On `AutoConnect.connected?()` -> transition to WATCH phase
   - Log: "Monitor connected to worker@giulia-worker"

3. **WATCH**: Enter idle polling mode
   - Collector is already watching the worker node (via AutoConnect -> watch_node)
   - Monitor GenServer enters `:idle` state

4. **BURST DETECTED**: Collector notifies monitor
   - Monitor stores burst start timestamp
   - Optionally: take a "before" pulse snapshot for delta comparison

5. **BURST ENDED**: Collector delivers captured snapshots
   - Monitor calls `Profiler.produce_profile/3`

6. **PROFILING -> IDLE reset** (explicit — easy to forget, stuck forever without it):
   - `produce_profile/3` returns, profile saved to CubDB
   - Reset `state.mode` to `:idle`
   - Clear burst snapshot buffer
   - Re-establish baseline reductions/s from current (now-idle) worker pulse
   - Reschedule idle poll: `Process.send_after(self(), :collect, idle_interval)`
   - Log: "Profile saved. Returning to idle monitoring."
   - Monitor is now ready to detect the next burst

#### 7. Performance Profile Generation

**New file**: `lib/giulia/runtime/profiler.ex`

Pure function module (no GenServer). Takes burst snapshots + Giulia's Knowledge Graph
and produces a fused performance profile. **Fully offline — no LLM dependency.**

Input:
- List of runtime snapshots from the burst window (pulse + top_processes at 500ms)
- Giulia's Knowledge Graph (from local ETS, built in boot step)
- Giulia's per-function cognitive complexity (from local ETS, Build 130)

Output: Performance profile map:
```elixir
%{
  duration_ms: 14_200,
  peak_memory_mb: 280,
  memory_delta_mb: +45,
  peak_process_count: 312,
  peak_run_queue: 3,

  hot_modules: [
    %{
      module: "Giulia.Context.Indexer",
      reductions_pct: 42.1,
      memory_mb: 38.5,
      knowledge_graph: %{
        in_degree: 3,
        out_degree: 8,
        zone: :yellow,
        score: 45
      },
      hottest_functions: [
        %{name: :do_scan, arity: 1, cognitive_complexity: 9},
        %{name: :process_file, arity: 1, cognitive_complexity: 4}
      ]
    },
    # ... top 10
  ],

  bottleneck_analysis: [
    "Indexer consumed 42% of CPU. do_scan/1 has complexity 9 — consider splitting.",
    "EmbeddingServing allocated 45MB — peak memory contributor."
  ]
}
```

**`bottleneck_analysis` is template-generated**, not LLM. Hardcoded patterns:
- `"{module} consumed {pct}% of CPU. {func}/{arity} has complexity {n} — consider splitting."`
- `"{module} allocated {mb}MB — peak memory contributor."`
- `"Run queue peaked at {n} — scheduler contention detected during {phase}."`

Sub-millisecond generation, fully offline. The profiler has zero provider dependency.
If an LLM-powered narrative is desired in the future, it would be a separate optional
endpoint that wraps the profile data, not embedded in the profiler itself.

Storage: Save profiles to CubDB under `{:profile, project_path, timestamp}`.

#### 8. Profile REST Endpoints

**Modify**: `lib/giulia/daemon/routers/runtime.ex`

New endpoints on the monitor:
- `GET /api/runtime/profiles` — list saved profiles (timestamps, durations)
- `GET /api/runtime/profile/:id` — full profile detail
- `GET /api/runtime/profile/latest` — most recent profile

---

### Build 133: Dashboard Enhancements (Optional)

#### 9. Dashboard Enhancement

**Modify**: `lib/giulia/daemon/routers/monitor.ex`

Monitor dashboard shows:
- Worker connection status (connected/disconnected/reconnecting)
- Worker pulse data alongside local pulse (side-by-side)
- Burst detection state (idle/capturing/profiling)
- Latest profile summary

---

## File Summary

| File | Action | Build |
|---|---|---|
| `lib/giulia/role.ex` | New — role detection (3 lines) | 131 |
| `lib/giulia/application.ex` | Modify — role-aware child gating + AutoConnect | 131 |
| `docker-compose.yml` | Modify — parameterize node name, add monitor service | 131 |
| `lib/giulia/runtime/auto_connect.ex` | New — auto-connect GenServer | 131 |
| `lib/giulia/runtime/collector.ex` | Modify — multi-node, burst detection | 131 |
| `CLAUDE.md` | Modify — document new env vars | 131 |
| `lib/giulia/runtime/monitor.ex` | New — monitor lifecycle orchestrator | 132 |
| `lib/giulia/runtime/profiler.ex` | New — profile generation (pure functions, no LLM) | 132 |
| `lib/giulia/daemon/routers/runtime.ex` | Modify — profile endpoints | 132 |
| `lib/giulia/daemon/routers/monitor.ex` | Modify — enhanced dashboard | 133 |

## New Environment Variables

| Variable | Default | Used By | Purpose |
|---|---|---|---|
| `GIULIA_NODE_NAME` | `giulia@0.0.0.0` | docker-compose command | Erlang node name (CLI flag, not Elixir code) |
| `GIULIA_CONNECT_NODE` | unset | AutoConnect | Target node to watch (e.g., `worker@giulia-worker`) |
| `GIULIA_ROLE` | `standalone` | Role module | `worker`, `monitor`, or `standalone` |
| `GIULIA_DIST_PORT_MIN` | `9100` | docker-compose command | Erlang distribution port range start |
| `GIULIA_DIST_PORT_MAX` | `9105` | docker-compose command | Erlang distribution port range end |

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Docker DNS not ready when monitor starts | AutoConnect retries with exponential backoff (5s->60s cap) |
| EPMD cross-container discovery | Docker Compose default bridge network handles container name resolution |
| Cookie mismatch | Both services share `${GIULIA_COOKIE}` from same env |
| Monitor OOM from EmbeddingServing | Role gating in Build 131 — monitor never starts embedding model |
| Monitor scan of Giulia source adds startup time | CubDB persistence — warm restart after first scan |
| Burst detection false positives | 3x baseline threshold + 3 consecutive drops to exit. Tunable. |
| Collector 500ms sampling overhead on monitor | Negligible — pulse is 5 BIFs, top_processes iterates ~200 PIDs |
| Profile storage grows unbounded | CubDB compaction + configurable retention (keep last N profiles) |

## What This Enables

After Build 132, running `docker compose up -d` gives you:

1. Worker scans projectX (heavy workload, real CPU/memory pressure)
2. Monitor detects the burst, captures 500ms snapshots throughout
3. Burst ends, monitor produces a profile:
   - "Indexer consumed 42% of reductions, Complexity module 18%, Graph builder 15%"
   - "do_scan/1 has cognitive complexity 9 — highest in the hot path"
   - "EmbeddingServing allocated 45MB during scan — peak memory contributor"
4. Profile is queryable via REST: `GET monitor:4001/api/runtime/profile/latest`

That's measurable, repeatable, self-improvement data. Make a change to Giulia,
rebuild both containers, run the same scan, compare profiles. Father-killing with evidence.
