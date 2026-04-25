> **Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia)** — Local-first AI code intelligence for the BEAM.

# Bandit v1.10.4 — Project Analysis Report

## Section 1: Executive Summary

| Metric | Value |
|---|---|
| Source files | 67 |
| Modules | 72 |
| Functions (def + defp) | 439 |
| Public functions | 278 |
| Private functions | 161 |
| Public ratio | 63.3% |
| Types | 62 |
| Specs | 154 |
| Spec coverage | 154 / 278 public functions (55.4%) |
| Structs | 28 |
| Callbacks | 3 |
| Graph vertices | 550 |
| Graph edges | 634 |
| Connected components | 143 |
| Circular dependencies | 2 |
| Behaviour fractures | 0 |
| Orphan specs | 6 |
| Dead code | 3 / 439 (0.68%) |

**Verdict:** Healthy library with strong spec coverage (55.4% — among the highest seen) and a single concentrated risk surface (Bandit.HTTP2.Stream: red zone, change_risk 3,096, 49 functions, complexity 116, fan-in 16). The two cycles are large but reflect genuine bidirectional protocol-frame coupling — both HTTP/2 and WebSocket frame modules form honest mutual-reference rings, not architectural mistakes. Public ratio 63% is high but appropriate for a server library exposing many frame/transport types as public API.

---

## Section 2: Heatmap Zones

| Zone | Count |
|---|---|
| Red (≥ 60) | 1 |
| Yellow (30–59) | 38 |
| Green (< 30) | 36 |

### Red Zone

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Bandit.HTTP2.Stream | 75 | 116 | 16 | 15 | no |

### Yellow Zone — Top 10

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Bandit.HTTP2.Errors | 53 | 3 | 14 | 1 | no |
| Bandit.Pipeline | 45 | 31 | 5 | 18 | no |
| Bandit.Logger | 39 | 7 | 6 | 4 | no |
| Bandit.HTTP2.Connection | 38 | 54 | 1 | 12 | no |
| Bandit.TransportError | 37 | 0 | 6 | 0 | no |
| Bandit.Telemetry | 37 | 8 | 4 | 8 | no |
| Bandit.Adapter | 36 | 35 | 1 | 13 | no |
| SimpleH2Client (test/support) | 36 | 45 | 0 | 15 | no |
| Bandit.HTTPTransport | 35 | 12 | 4 | 4 | no |
| Bandit.HTTP2.Errors.StreamError | 35 | 3 | 5 | 0 | no |

(28 more yellow modules below score 35 — mostly small WebSocket / HTTP2 frame structs, error types, and connection helpers.)

### Test Coverage Gap Analysis

**Striking pattern: the red-zone module and 9 of the top 10 yellow modules all have `has_test = false`.** This is significant because the heatmap formula adds 25 points for missing tests — without that floor, several yellow entries would drop into green.

| Module | Reason | Actionable? |
|---|---|---|
| Bandit.HTTP2.Stream | Heavy state machine; tests live in `test/bandit/http2/` integration suites under different file names | by-design (integration-tested) |
| Bandit.HTTP2.Errors | Error code mapping module | by-design (exercised via integration) |
| Bandit.Pipeline | Core request pipeline | actionable (worth a focused unit test file) |
| Bandit.Logger | Telemetry-event-to-log adapter | by-design (Logger is hard to test in isolation) |
| Bandit.HTTP2.Connection | State machine (54 complexity) | by-design (integration-tested via HTTP/2 protocol tests) |
| Bandit.TransportError | Bare exception | by-design |
| Bandit.Telemetry | Event definitions | by-design (events emitted under integration tests) |
| Bandit.Adapter | Plug.Conn adapter implementation | actionable — protocol-conformance tests would protect this |
| SimpleH2Client | Test helper itself | by-design |
| Bandit.HTTPTransport | Behaviour module | by-design |

The pattern is heavy reliance on integration tests (`test/bandit/http1_test.exs`, `test/bandit/http2_test.exs`, etc.) rather than per-module unit tests. This is a defensible architectural choice for a protocol implementation — you can't meaningfully unit-test a stream module without the connection state machine — but it does inflate heatmap scores.

**Red zone gut check:** `Bandit.HTTP2.Stream` would still be red even with `has_test=true`: 75 - 25 = 50, still well into red. The score is real, driven by complexity 116 and fan-in 16.

---

## Section 3: Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Bandit.HTTP2.Stream | 16 | 8 | Bidirectional hub — central state machine; modifying it cascades through every HTTP/2 frame handler |
| Bandit.HTTP2.Errors | 14 | 0 | Pure hub — error-code registry consumed everywhere, depends on nothing |
| Bandit.HTTP2.Frame | 13 | 14 | Bidirectional hub — defprotocol entry point + reflective frame parsing |
| Bandit.WebSocket.Frame | 10 | 8 | Bidirectional hub — WebSocket parallel of HTTP2.Frame |
| Bandit.HTTP2.Frame.Serializable | 10 | 0 | Pure hub — defprotocol implemented by every HTTP/2 frame variant |

---

## Section 4: Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|---|---|---|---|
| 1 | Bandit.HTTP2.Stream | 3,096 | Centrality 16 × public+private 49 × complexity 116 — multiplicative compound, the dominant risk surface |
| 2 | Bandit.WebSocket.Frame | 642 | Centrality 10 × surface as protocol entry point for every frame type |
| 3 | Bandit.HTTP2.Frame | 465 | Centrality 13 × frame-parser breadth |
| 4 | Bandit.Pipeline | 455 | Complexity 31 × max_coupling 18 (highest in project) |
| 5 | Bandit | 402 | Top-level macro module + max_coupling 28 (Keyword config plumbing) |
| 6 | Bandit.HTTP1.Socket | 337 | Complexity 74 — large socket/buffer state machine |
| 7 | Bandit.HTTP2.Connection | 306 | Complexity 54 + fan_out 23 (orchestrator) |
| 8 | Bandit.WebSocket.Frame.Serializable | 292 | Centrality 7 × protocol surface |
| 9 | Bandit.Headers | 269 | Centrality 5 × header-parsing complexity |
| 10 | Bandit.SocketHelpers | 262 | Centrality 5 × socket utility breadth |

---

## Section 5: God Modules

| Module | Functions | Complexity | Score |
|---|---|---|---|
| Bandit.HTTP2.Stream | 49 | 116 | 329 |
| Bandit.HTTP1.Socket | 29 | 74 | 180 |
| Bandit.HTTP2.Connection | 18 | 54 | 129 |
| SimpleH2Client (test/support) | 22 | 45 | 112 |
| Bandit.WebSocket.Connection | 16 | 40 | 99 |
| Bandit.Adapter | 17 | 35 | 90 |
| Bandit.WebSocket.Frame | 9 | 25 | 89 |
| Bandit.Pipeline | 11 | 31 | 88 |
| SimpleWebSocketClient (test/support) | 21 | 26 | 73 |
| Bandit.Compression | 9 | 30 | 72 |

Commentary:

- **Bandit.HTTP2.Stream**: top change_risk + top god module + only red-zone module. **The single concentrated refactor candidate in the codebase.** 49 functions implementing the HTTP/2 stream lifecycle — receive-window flow control, state transitions, frame ordering, error mapping. Per-function complexity is too low to surface (no function ≥ 5 cognitive complexity, even with `min=5`). The complexity is *spread broadly* — many small state-aware functions — which is honest for a protocol state machine but fragile. **Splitting candidates**: separate flow-control logic from frame-handling logic; extract state-transition table.
- **Bandit.HTTP1.Socket**: 29 functions on the HTTP/1 buffered-read state machine. Same pattern — small handlers, honest protocol complexity. Centrality 1 → low blast radius if refactored.
- **Bandit.HTTP2.Connection**: connection-level state machine with fan_out 23 (most in the project). It orchestrates streams, settings, flow control, and goaway negotiation. Honest complexity; centrality 1 → low refactor risk.
- **SimpleH2Client / SimpleWebSocketClient**: test support modules. Centrality 0 means nothing in `lib/` depends on them. **Not refactor candidates** — by-design test helpers, complexity reflects the real protocols they exercise.
- **Bandit.Pipeline**: 11 functions but complexity 31 and **max_coupling 18** (highest in the project). This is the request-handling orchestrator — calls Plug.Conn manipulation, transport, telemetry, adapter functions. The high coupling is structural (it's the central pipeline) but worth watching for further accretion.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

### Bandit.HTTP2.Stream (change_risk rank #1)

Direct dependents: 16 modules — the entire HTTP/2 subsystem.

```
Bandit.HTTP2.Connection, Bandit.HTTP2.Frame, Bandit.HTTP2.Frame.Continuation,
Bandit.HTTP2.Frame.Data, Bandit.HTTP2.Frame.Goaway, Bandit.HTTP2.Frame.Headers,
Bandit.HTTP2.Frame.Ping, Bandit.HTTP2.Frame.Priority, Bandit.HTTP2.Frame.PushPromise,
Bandit.HTTP2.Frame.RstStream, Bandit.HTTP2.Frame.Settings, Bandit.HTTP2.Frame.Unknown,
Bandit.HTTP2.Frame.WindowUpdate, Bandit.HTTP2.Handler, Bandit.HTTP2.StreamCollection,
Bandit.HTTP2.StreamProcess
```

Total blast radius: 16 modules at depth 1 — essentially every HTTP/2 module. Modifying `Bandit.HTTP2.Stream` is HTTP/2-wide breaking-change territory.

**Cascading hub risk**: depth-1 includes `Bandit.HTTP2.Frame` (Top 5 Hub #3), so a Stream change cascades through Frame to its 13 dependents — most of which are already in the Stream depth-1 list (the HTTP/2 subsystem is densely interconnected).

### Bandit.WebSocket.Frame (change_risk rank #2)

Direct dependents: 10 modules — the entire WebSocket subsystem.

```
Bandit.WebSocket.Connection, Bandit.WebSocket.Frame.Binary, ConnectionClose,
Continuation, Ping, Pong, Text, Bandit.WebSocket.Handler, Bandit.WebSocket.Socket,
Bandit.WebSocket.Socket.ThousandIsland.Socket
```

Total blast radius: 10 modules. Mirror structure to HTTP/2 — entry-point protocol module + per-frame-type variants + connection/handler/socket adapters. Same all-or-nothing modification surface.

### Bandit.HTTP2.Frame (change_risk rank #3)

Direct dependents: 13 modules — every HTTP/2 frame variant + the connection + handler.

```
Bandit.HTTP2.Connection, Bandit.HTTP2.Frame.Continuation, Data, Goaway, Headers,
Ping, Priority, PushPromise, RstStream, Settings, Unknown, WindowUpdate,
Bandit.HTTP2.Handler
```

Total blast radius: 13 modules. The 12 sibling frame modules implement `Bandit.HTTP2.Frame.Serializable` — a defprotocol; changes to the dispatch entry-point ripple through every implementer.

---

## Section 7: Unprotected Hubs

| Module | In-Degree | Spec Coverage | Severity |
|---|---|---|---|
| Bandit.HTTP2.Frame.Serializable | 10 | 0% | red |
| Bandit.WebSocket.Frame.Serializable | 7 | 0% | red |
| Bandit.Logger | 6 | 0% | red |
| Bandit.HTTP2.Frame.Flags | 5 | 0% | red |
| Transport (test/support) | 3 | 0% | red |
| Bandit.HTTP2.Stream | (in red zone, see above) | 0% | red |
| Bandit.WebSocket.Frame | (Top 5 Hub) | 0% | red |

**Insight:** 154 specs project-wide, well-distributed across modules with concrete data types. The hubs that lack specs are mostly **defprotocol entry points** — `Bandit.HTTP2.Frame.Serializable` and `Bandit.WebSocket.Frame.Serializable` define the protocol but the spec lives on each implementer (which is normal for `defprotocol`). The actual concerning gap is `Bandit.Logger` (6 dependents, 0 specs, 2 functions) — small surface, high consumer count, mechanical fix.

Sorted by `in_degree × (1 − spec_ratio)`: Frame.Serializable (10.0) > Frame.Serializable WebSocket (7.0) > Logger (6.0) > Frame.Flags (5.0).

---

## Section 8: Coupling Analysis (Top 10 Pairs)

After ignoring stdlib coupling (Keyword, Enum, Map, IO, String):

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Bandit.Pipeline | Plug.Conn | 18 | 8 |
| Bandit.HTTP2.Connection | Bandit.HTTP2.Stream | 12 | 6 |
| Bandit.HTTP2.Handler | Bandit.HTTP2.Connection | 12 | 8 |
| Bandit.HTTP1.Socket | ThousandIsland.Socket | 12 | 4 |
| Bandit.Pipeline | Bandit.HTTPTransport | 11 | 5 |
| Bandit.HTTP2.Connection | Bandit.HTTP2.Errors | 11 | 7 |
| Bandit.HTTP2.Stream | Bandit.HTTP2.Errors | 11 | 7 |
| Bandit.Adapter | Bandit.HTTPTransport | 10 | 10 |

All by-design:

- `Pipeline → Plug.Conn`: this is what an HTTP server does — wrap Plug.Conn manipulation.
- `Handler → Connection → Stream`: the standard layered architecture; each layer has 12 distinct call sites into the next, which is the right pattern.
- `*.Errors` couplings: error-code emitter pattern — both Connection and Stream emit the full error vocabulary, expected.
- `HTTP1.Socket → ThousandIsland.Socket`: dependency on the underlying socket library, expected.

No unexpected pair. No "mystery coupling."

---

## Section 9: Dead Code

| Module | Function | Line |
|---|---|---|
| Bandit.Clock | init/0 | 38 |
| Bandit.Trace | get_events/0 | 80 |
| Bandit.Trace | stop_tracing/0 | 72 |

**3 / 439 functions (0.68%) flagged dead.** Categorization:

1. **`Bandit.Clock.init/0` — TOOL GAP (universal, fixable).** Invoked at `clock.ex:34` via `Task.start_link(__MODULE__, :init, [])`. This is MFA-form invocation — `Task.start_link/3`'s first three args ARE the M, F, A — but Pass 10's apply detection only matches `apply(M, F, A)` and `Kernel.apply(...)`. The same `(<module_or_alias>, <:atom_literal>, <list_literal>)` arg-shape inside ANY 3-arg call is also an MFA reference, but Pass 10 currently only recognizes it under `:apply` heads. **General fix**: extend Pass 10 to match the MFA shape inside any 3-arg call where arg1 is `__MODULE__` or `__aliases__`. This stays universal — no allowlist of "Task.start_link / GenServer / Supervisor known APIs", just shape-detection. Same false-positive analysis as Pass 10's existing logic. Low risk; 30-minute slice.

2. **`Bandit.Trace.get_events/0` — public API for IEx use.** Documented in `@moduledoc` line 9 (`iex> Bandit.Trace.start_tracing()` ... `Bandit.Trace.get_events()`). Intended to be called from a remote shell attached to a running Bandit instance, not from any code in the codebase. Same accept-as-residual category as Plausible's `Endpoint.app_env_config/0` and Plug's `delete_csrf_token/0`.

3. **`Bandit.Trace.stop_tracing/0` — public API for IEx use.** Same as above, documented as `iex> Bandit.Trace.stop_tracing()` in the moduledoc.

So: 1 closeable tool gap + 2 accept-as-residual library-public-from-IEx entries.

---

## Section 10: Struct Lifecycle

28 structs total. Top by leak count:

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|---|---|---|---|---|
| Bandit.HTTP2.Frame.Continuation | Bandit.HTTP2.Frame.Continuation | 3 | 2 | 2 |
| Bandit.HTTP2.Frame.Settings | Bandit.HTTP2.Frame.Settings | 2 | 1 | 1 |
| Bandit.HTTP2.Settings | Bandit.HTTP2.Settings | 1 | 1 | 1 |
| Bandit.HTTP1.Socket | Bandit.HTTP1.Socket | 1 | 1 | 1 |
| Bandit.HTTP2.Frame.Goaway | Bandit.HTTP2.Frame.Goaway | 2 | 1 | 1 |

All very localized — no leak count above 2. Bandit's 28 structs are mostly tightly-scoped per-frame-type structs that are pattern-matched by exactly one or two consumers (the frame parser and the connection that handles the frame). This is **idiomatic Elixir** — not encapsulation violations. The frame-struct pattern matching IS the wire-protocol decoder.

---

## Section 11: Semantic Duplicates

4 clusters detected.

| Cluster | Avg Similarity | Members |
|---|---|---|
| NoopWebSock (test/support) | 94.3% | __using__/1, init/1, handle_in/2 (5 members total) |
| Bandit.PhoenixAdapter | 94.0% | bandit_pid/2, server_info/2, child_specs/2 |
| Transport (test/support) | 89.4% | send/2, recv/2 |

**Verdict: structural similarity, not duplication.**

- `NoopWebSock` is a test fixture — a no-op WebSock implementation across multiple test scenarios; the 5 functions are all 1–2 line stubs that share AST shape.
- `Bandit.PhoenixAdapter` cluster is 3 small helper functions with similar parameter shapes (each is a thin wrapper around supervisor introspection).
- `Transport` (test support) cluster is `send/recv` — the inverse pair, identically-shaped.

Not actionable. Same false-positive class as Plug's GenServer skeleton clusters.

---

## Section 12: Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | 2 cycles found |
| Behaviour integrity | Consistent (0 fractures) |
| Orphan specs | 6 |
| Dead code | 3 functions (1 tool gap, 2 IEx-public — see Section 9) |

### Cycles

1. **HTTP/2 mega-cycle (25 modules)**: `Bandit ↔ Adapter ↔ HTTP1.Handler ↔ HTTP1.Socket ↔ HTTP2.Connection ↔ HTTP2.Frame ↔ <12 frame variants> ↔ HTTP2.Handler ↔ HTTP2.Stream ↔ HTTP2.StreamCollection ↔ HTTP2.StreamProcess ↔ HTTPTransport ↔ InitialHandler ↔ Pipeline ↔ SocketHelpers`. This is one large strongly-connected component covering essentially the entire Bandit core. The cycle is driven by:
   - `Bandit.HTTP2.Frame` is a defprotocol — every frame variant module has a "depends_on" edge back to it (via the protocol declaration), AND Frame depends on its variants (via the dispatch surface). This alone produces a 12-module cycle.
   - `Pipeline → HTTPTransport → HTTP1.Socket → HTTP2.Connection → Stream → Handler → Pipeline` is the closure for request handling.

2. **WebSocket frame cycle (7 modules)**: `WebSocket.Frame ↔ Frame.Binary ↔ ConnectionClose ↔ Continuation ↔ Ping ↔ Pong ↔ Text`. Same pattern as HTTP/2 frame cycle — defprotocol entry point + every implementer.

**Severity: P3 (informational).** Both cycles are honest defprotocol-with-many-impls patterns. Not architectural failures. Worth noting in `ARCHITECTURE.md` so external reviewers understand the protocol-frame coupling is intentional.

### Orphan Specs (6)

6 spec definitions with no matching function. Likely candidates: post-refactor leftovers or specs for functions removed in recent versions. Worth a `mix dialyzer` pass to confirm and clean up.

---

## Section 13: Runtime Health

Not applicable — Bandit v1.10.4 is being analyzed statically; no live BEAM node was attached for runtime introspection.

---

## Section 14: Recommended Actions (Priority Order)

### P0 — none

No blocking issues.

### P1 — high-risk gaps

Sorted by `in_degree × (1 − spec_ratio)`:

1. **Spec coverage on Bandit.Logger** (6 dependents × 0% specs = 6.0). 2 public functions (`info/2`, `error/2` style telemetry-event loggers). Mechanical add — 5 minutes.
2. **Document the defprotocol cycles in ARCHITECTURE.md or README**. Both HTTP/2 and WebSocket frame-protocol cycles are visible to any static-analysis reviewer; an explicit one-paragraph note that "the 25-module HTTP/2 cycle is a defprotocol-implementer ring, not a dependency mistake" forecloses confusion.
3. **Add per-module unit tests for Bandit.Pipeline** (max_coupling 18 — highest in project, currently relying on integration tests). The orchestrator deserves direct test coverage; integration regressions would be hard to localize.
4. **Add specs to Transport behaviour spec module** (`test/support/transport.ex`) so test client code has a typed contract.

### P2 / P3 — improvement opportunities (capped at 3)

5. **Investigate Bandit.HTTP2.Stream split**: only red-zone module + top change_risk + top god module. Per-function complexity is uniformly low, so the right split is by *concern* (flow-control, state-transition table, frame-ordering) not by function-extraction. Substantial work; flag as long-term.
6. **Clean the 6 orphan specs** via a `mix dialyzer` pass — likely refactor leftovers; mechanical.
7. **Investigate the 2 IEx-public dead-code residuals (`Bandit.Trace.get_events/0`, `stop_tracing/0`)** — if `Bandit.Trace` is still considered experimental (per its `@moduledoc`), no action needed. If it's stabilizing, consider documenting the public API surface in the official reference docs so `mix docs` surfaces it.

### Tool finding (out-of-scope for this report, queued for next slice)

`Bandit.Clock.init/0` exposes a Pass 10 gap — `Task.start_link(__MODULE__, :init, [])` is MFA-form dispatch but the third-party `Task.start_link/3` head doesn't match Pass 10's `:apply`-only filter. **General fix proposed**: extend Pass 10 to recognize the MFA arg-shape inside any 3-arg call. Universal mechanism (no library allowlist), preserves the conservative skip semantics, half-session of work.

---

*Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia) v0.2.2.155 — /projects/bandit-main — 2026-04-25*
