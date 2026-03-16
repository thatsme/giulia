# Security Policy

## Reporting a Vulnerability

Please do NOT open a public GitHub issue for security vulnerabilities.

Contact: development@securtel.net
Expected response: within 72 hours
Coordinated disclosure: 90 days before public disclosure requested

---

## Design Philosophy

Giulia is a **local development tool**. It runs on the developer's machine,
accessible only on localhost. There is no authentication layer by design —
the threat model assumes the operator controls the host.

This does NOT mean security is ignored. Giulia handles untrusted input
(file contents, LLM responses, HTTP query parameters) and must defend
against injection, resource exhaustion, and path traversal.

---

## Path Sandbox

Giulia can ONLY access files under the project root (the directory containing
`GIULIA.md`, the project constitution). All file operations go through
`Giulia.Core.PathSandbox`:

```elixir
PathSandbox.validate(sandbox, path)
# Expands to absolute path, verifies containment
# Rejects: "../", symlink escape, null bytes
```

The LLM cannot request files outside the sandbox. If a tool call tries to
read `/etc/passwd` or `~/.ssh/config`, the sandbox rejects it before any
I/O occurs.

---

## Atom Safety

Erlang atoms are never garbage collected. Creating atoms from untrusted input
is a memory leak that eventually crashes the VM.

Giulia enforces:

- **HTTP query parameters** (`?node=`) are validated against `name@host` format
  before conversion via `safe_to_node_atom/1`
- **Function/module names** from tool calls use `String.to_existing_atom/1`
  (only atoms already known to the VM from compilation)
- **Integer parsing** uses `Integer.parse/1` (returns tagged tuple) instead of
  `String.to_integer/1` (raises on invalid input)

See `Giulia.Daemon.Helpers.safe_to_node_atom/1` for the implementation.

---

## Secrets Management

No hardcoded secrets, salts, or keys in source code.

All external credentials are resolved through environment variables:

| Secret | Variable | Required |
|--------|----------|----------|
| Anthropic API key | `ANTHROPIC_API_KEY` | For cloud provider |
| Groq API key | `GROQ_API_KEY` | For Groq provider |
| Gemini API key | `GEMINI_API_KEY` | For Gemini provider |
| Erlang cookie | `GIULIA_COOKIE` | For distributed Erlang auth |
| ArcadeDB password | `ARCADEDB_PASSWORD` | Giulia's HTTP auth to ArcadeDB. Must match `rootPassword` in ArcadeDB's `JAVA_OPTS`. |

The Erlang distribution cookie authenticates inter-node communication.
Both worker and monitor must share the same cookie. Default is `giulia_dev` —
change this in production or multi-user environments.

---

## LLM Prompt Security

Giulia sends project code to external LLM providers (Anthropic, Gemini, Groq,
LM Studio). Be aware:

- **Cloud providers** (Anthropic, Gemini, Groq): project source code is sent
  over HTTPS to external servers. Review provider data retention policies.
- **Local providers** (LM Studio, Ollama): all data stays on your machine.
- The **Provider Router** classifies tasks and selects the appropriate provider.
  High-intensity tasks go to cloud; micro-tasks stay local.

Giulia never sends data to any provider without an explicit tool call from
the inference engine. There is no background telemetry or analytics.

---

## HTTP API Security

The HTTP API (Bandit on port 4000) has no authentication. It is designed for
localhost access only.

Defenses against malicious input:

- **JSON body parsing**: Plug.Parsers with configurable size limits
- **Query parameter validation**: type checking and default fallbacks
- **SQL injection (ArcadeDB)**: parameterized queries via Req, never string interpolation
  of user input into SQL (except `escape/1` for graph write helpers)
- **Path traversal**: all `?path=` parameters go through PathMapper and PathSandbox

---

## Distributed Erlang

The worker and monitor communicate via Erlang distribution (ports 4369, 9100-9115).

Security considerations:

- **Cookie authentication**: both nodes must share `GIULIA_COOKIE`
- **Network scope**: distribution ports should NOT be exposed to untrusted networks
- **Remote node access**: `POST /api/runtime/connect` accepts a node name and
  optional cookie. The node name is validated against `name@host` format before
  atom conversion.

If you expose Giulia's ports beyond localhost (e.g., for remote development),
use a VPN or SSH tunnel. Never expose EPMD (4369) or distribution ports
(9100-9115) to the public internet.

---

## Deployment Hardening

- Bind to localhost only — do not expose port 4000 to untrusted networks
- Change `GIULIA_COOKIE` from the default `giulia_dev`
- Change the ArcadeDB root password from the default `playwithdata` — set it in both places: ArcadeDB's `JAVA_OPTS` (`-Darcadedb.server.rootPassword=...`) and Giulia's `ARCADEDB_PASSWORD` env var
- Do not expose EPMD (4369) or distribution ports (9100-9115) publicly
- Review which LLM providers are enabled before processing sensitive code
- ArcadeDB REST API (port 2480) has its own auth — do not expose without password

---

## Scope

Giulia is designed as a single-developer local tool. Multi-user access control,
rate limiting, and session management are not in scope. The security model
assumes a single trusted operator on a trusted machine.

---

*Giulia — Copyright 2026 Alessio Battistutta — Apache License 2.0*
