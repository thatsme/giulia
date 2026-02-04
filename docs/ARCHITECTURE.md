# Giulia Architecture

## Overview

Giulia is an AI development agent built on the Erlang/OTP platform. Unlike stateless CLI tools, Giulia runs as a **persistent background daemon** with multi-project awareness, concurrent task execution, and fault-tolerant supervision.

The key architectural insight: **The model is the brain, Giulia is the exoskeleton.** Without the exoskeleton, the brain is just dreaming; without the brain, the exoskeleton is just a pile of metal.

## Daemon-Client Architecture

Giulia is designed as a system-wide service, not a per-directory script:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SYSTEM-WIDE DEPLOYMENT                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Terminal A (~/projects/alpha)        Terminal B (~/projects/beta)          │
│  ┌─────────────────────────────┐      ┌─────────────────────────────┐       │
│  │  $ giulia "add tests"       │      │  $ giulia "fix bug"         │       │
│  │        │                    │      │        │                    │       │
│  │        ▼                    │      │        ▼                    │       │
│  │   [Thin Client]             │      │   [Thin Client]             │       │
│  └────────┬────────────────────┘      └────────┬────────────────────┘       │
│           │                                    │                             │
│           │    HTTP POST /api/command          │                             │
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
│  │  │                  │    │  - Chat History  │                      │     │
│  │  │                  │    └──────────────────┘                      │     │
│  │  │                  │    ┌──────────────────┐                      │     │
│  │  │                  │───▶│  ProjectContext  │ (beta)               │     │
│  │  │                  │    │  - AST Index     │                      │     │
│  │  │                  │    │  - Constitution  │                      │     │
│  │  │                  │    │  - Chat History  │                      │     │
│  │  └──────────────────┘    └──────────────────┘                      │     │
│  │                                                                     │     │
│  │  /data/ (Docker volume)   Per-project: .giulia/                    │     │
│  │    ├── cache/               ├── cache/                             │     │
│  │    └── state/               └── history/chat.db                    │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why HTTP Instead of Erlang Distribution?

**The Problem with Erlang Distribution + Docker:**

Erlang distribution requires bi-directional connections. When client connects to daemon,
the daemon tries to connect BACK to the client. Inside Docker:
- `127.0.0.1` means the container's loopback, not the host
- The return connection fails because IPs don't mean the same thing
- EPMD (Erlang Port Mapper Daemon) adds another layer of complexity

**The Solution: Simple HTTP/JSON via Bandit**

HTTP is unidirectional - client sends request, server responds. No return connection needed.
Port forwarding works perfectly. No EPMD drama.

### Why Daemon-Client?

1. **Warm LLM**: Local models (Qwen 3B) take time to load. Keep them warm.
2. **Hot AST Cache**: Don't re-index 500 files every terminal session.
3. **Multi-Project**: Work on alpha and beta simultaneously, isolated contexts.
4. **System-Wide**: Type `giulia` anywhere. It just works.

### Client Modules

Giulia has two client implementations (for historical reasons):

| Module | File | Transport | Status |
|--------|------|-----------|--------|
| `Giulia.Client` | `lib/giulia/client.ex` | HTTP (Req) | **Active** - Used by escript |
| `Giulia.CLI` | `lib/giulia/cli.ex` | Erlang RPC | Legacy - Requires same-node or distribution |

The **HTTP client** (`Giulia.Client`) is the current implementation because:
- Works across Docker boundaries (no bi-directional handshake)
- Simple port forwarding on 4000
- No EPMD dependency
- Compiled to escript via `mix escript.build`

The legacy `Giulia.CLI` module still exists but uses Erlang distribution which doesn't
work reliably with Docker's networking model.

### The Client Flow

```elixir
# User types: giulia "add tests to user module"
# 1. Client sends HTTP POST to http://localhost:4000/api/command
#    Body: {"message": "add tests...", "path": "/projects/alpha"}
# 2. Daemon's ContextManager checks: Do I have a ProjectContext for this path?
#    - Yes: Route to existing context
#    - No:  Does GIULIA.md exist?
#           - Yes: Spawn new ProjectContext
#           - No:  Return {"status": "needs_init"}
# 3. ProjectContext handles request within its sandbox
# 4. Response returned as JSON: {"status": "ok", "response": "..."}
```

### HTTP API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check for container readiness |
| `/api/status` | GET | Daemon status (uptime, active projects) |
| `/api/projects` | GET | List active project contexts |
| `/api/init` | POST | Initialize a new project (creates GIULIA.md) |
| `/api/command` | POST | Send chat message or command to daemon |
| `/api/index/modules` | GET | List all indexed modules (Pure Elixir, no LLM) |
| `/api/index/functions` | GET | List all indexed functions |
| `/api/index/summary` | GET | Get project summary for LLM context |
| `/api/index/scan` | POST | Trigger re-indexing of a directory |
| `/api/index/status` | GET | Show indexer status and progress |

## GIULIA.md: The Project Constitution

Every project gets a `GIULIA.md` file that acts as the **semantic anchor**:

```markdown
# MyProject - Giulia Constitution

## Tech Stack
- **Language**: Elixir
- **Framework**: Phoenix

## Taboos (Never Do This)
- Never use `import` for Phoenix controllers
- Never create umbrella projects
- Never add dependencies without explicit approval

## Preferred Patterns
- Use context modules for business logic
- Prefer pipe operators for data transformation
```

Giulia reads this on every interaction. If the model proposes code that violates a taboo, **Giulia sends it back for a rewrite before showing you**.

```elixir
# In Orchestrator.reflect_on_action/3
defp check_constitution(proposed_code, constitution) do
  Enum.each(constitution.taboos, fn taboo ->
    if violates_taboo?(proposed_code, taboo) do
      {:intercept, "CONSTITUTIONAL VIOLATION: #{taboo}"}
    end
  end)
end
```

## Core Supervision Tree

```
┌─────────────────────────────────────────────────────────────────┐
│                        BEAM VM (Erlang)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   Giulia.Supervisor                      │   │
│  │                    (one_for_one)                         │   │
│  └─────────────────────────────────────────────────────────┘   │
│        │         │         │         │         │         │      │
│        ▼         ▼         ▼         ▼         ▼         ▼      │
│  ┌─────────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ │
│  │Registry │ │Context│ │ Tools │ │Context│ │Provider│ │Agent  │ │
│  │ (named) │ │ Store │ │Registry│ │Indexer│ │  Sup  │ │  Sup  │ │
│  └─────────┘ │ (ETS) │ │ (ETS) │ │(GenSrv)│ │ (Dyn) │ │ (Dyn) │ │
│              └───────┘ └───────┘ └───────┘ └───────┘ └───────┘ │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐     │
│  │              PROJECT & HTTP SERVICES                    │     │
│  │  ┌───────────────┐  ┌──────────────┐  ┌─────────────┐  │     │
│  │  │ ProjectSup    │  │ContextManager│  │   Bandit    │  │     │
│  │  │ (DynamicSup)  │  │(Routes path  │  │ HTTP :4000  │  │     │
│  │  │      │        │  │ to Context)  │  │ (Plug API)  │  │     │
│  │  │ ┌────┴────┐   │  └──────────────┘  └─────────────┘  │     │
│  │  │ ▼         ▼   │                                     │     │
│  │  │Project  Project│                                    │     │
│  │  │Context  Context│                                    │     │
│  │  │(alpha)  (beta) │                                    │     │
│  │  └───────────────┘                                     │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**HTTP API (Bandit/Plug):**

The daemon exposes a REST API via Bandit (pure Elixir HTTP server):

```elixir
# lib/giulia/daemon/endpoint.ex
defmodule Giulia.Daemon.Endpoint do
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/health" do ... end
  post "/api/command" do ... end
  get "/api/status" do ... end
  # etc.
end
```

## Supervision Tree

### Root Supervisor (`Giulia.Application`)

Strategy: `:one_for_one` - If a child crashes, only that child restarts.

Children (in start order):
1. **Registry** - Named process lookup (Elixir Registry)
2. **Context.Store** - ETS table owner (must start before Indexer)
3. **Tools.Registry** - Auto-discovers and registers tools on boot
4. **Context.Indexer** - Background AST scanner
5. **Provider.Supervisor** - Dynamic supervisor for API connections
6. **Agent.Supervisor** - Dynamic supervisor for task agents
7. **Core.ProjectSupervisor** - Dynamic supervisor for per-project contexts
8. **Core.ContextManager** - Routes requests to correct ProjectContext by path
9. **Bandit** - HTTP server on port 4000 (Giulia.Daemon.Endpoint)

### Why This Order Matters

The Indexer depends on Store existing. Tools.Registry needs ETS available.
ContextManager depends on ProjectSupervisor for spawning contexts.
Bandit (HTTP endpoint) starts last so all services are ready before accepting requests.
OTP guarantees children start in order.

## The Integrated Feedback Loop

This is Giulia's core innovation over stateless CLI tools. We don't just send prompts—we manage a **State Machine** that constrains and corrects the model.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATOR STATE MACHINE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  THINK   │───▶│ VALIDATE │───▶│ REFLECT  │───▶│ EXECUTE  │          │
│  │  (LLM)   │    │ (Schema) │    │  (AST)   │    │ (Tools)  │          │
│  └──────────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘          │
│       ▲               │               │               │                 │
│       │          ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐          │
│       │          │CORRECTION│    │INTERCEPT │    │OBSERVATION│          │
│       │          │  (retry) │    │ (block)  │    │ (result) │          │
│       │          └────┬─────┘    └────┬─────┘    └────┬─────┘          │
│       │               │               │               │                 │
│       └───────────────┴───────────────┴───────────────┘                 │
│                                                                         │
│  State: { iteration, consecutive_failures, recent_errors, last_action } │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  LOOP OF DEATH PREVENTION                                         │  │
│  │  If consecutive_failures >= 3:                                    │  │
│  │    → Force context flush                                          │  │
│  │    → Send intervention message                                    │  │
│  │    → Reset state, keep iteration count                            │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### The 3-Step Verification

1. **VALIDATE** - Schema as Law
   - Model sends JSON action
   - Ecto changeset validates structure
   - Missing fields → Correction sent back to model
   - Unknown tool → Available tools listed in error

2. **REFLECT** - Skeptical Supervisor
   - Before execution, verify assumptions via AST
   - File doesn't exist? Check for similar paths
   - Destructive action? Verify target exists in index
   - Problem found → Intercept, don't execute

3. **EXECUTE** - Guarded Action
   - Only runs if validation AND reflection pass
   - Results become OBSERVATION for next iteration
   - Errors recorded for intervention context

## Data Flow

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   User CLI   │─────▶│    Giulia    │─────▶│    Router    │
└──────────────┘      └──────────────┘      └──────┬───────┘
                                                   │
                             ┌─────────────────────┼─────────────────────┐
                             │                     │                     │
                    ┌────────▼────────┐   ┌───────▼───────┐   ┌─────────▼─────────┐
                    │   LM Studio     │   │   Anthropic   │   │    Ollama         │
                    │  (local, 3B)    │   │   (cloud)     │   │  (local, 32B)     │
                    │  micro-tasks    │   │  heavy lift   │   │  medium tasks     │
                    └─────────────────┘   └───────────────┘   └───────────────────┘
                                                   │
                                          ┌───────▼───────┐
                                          │  Orchestrator │
                                          └───────┬───────┘
                      ┌───────────────────────────┼───────────────────────────┐
                      │                           │                           │
             ┌────────▼────────┐         ┌───────▼───────┐         ┌─────────▼─────────┐
             │ Context.Builder │         │ Tools.Registry│         │  StructuredOutput │
             │ (dynamic prompt)│         │ (capabilities)│         │  (JSON guardrails)│
             └────────┬────────┘         └───────┬───────┘         └─────────┬─────────┘
                      │                          │                           │
             ┌────────▼────────┐         ┌───────▼───────┐         ┌─────────▼─────────┐
             │  Context.Store  │         │  ReadFile     │         │   Ecto Changeset  │
             │     (ETS)       │         │  WriteFile    │         │   (validation)    │
             └────────┬────────┘         │  [future...]  │         └───────────────────┘
                      │                  └───────────────┘
             ┌────────▼────────┐
             │  AST.Processor  │
             │   (Sourceror)   │
             └─────────────────┘
```

## Component Details

### 1. Context Layer

#### Context.Store (ETS)

Holds all project state in a single ETS table:
- AST metadata keyed by file path
- Project configuration
- Persistent across terminal sessions (as long as BEAM runs)

```elixir
# Storage patterns
{{:ast, "/path/to/file.ex"}, %{modules: [...], functions: [...], ...}}
{:project_path, "/path/to/project"}
```

#### Context.Builder (Dynamic Prompts)

Builds the "System Constitution" for every LLM call:

```elixir
[
  %{role: "system", content: """
    === CONSTITUTION ===
    You are Giulia, an AI development agent...

    === AVAILABLE TOOLS ===
    - read_file(path): Read file contents
    - write_file(path, content, explanation): Write to file

    === ENVIRONMENT ===
    OS: Windows | Project: /path/to/project | Elixir: 1.17

    === PROJECT STATE ===
    Indexed Files: 12
    - application.ex: Giulia.Application (3 functions)
    - orchestrator.ex: Giulia.Agent.Orchestrator (15 functions)

    === CONSTRAINTS ===
    1. Respond with valid JSON only
    2. No conversational filler
    3. Do not repeat failed actions
  """},
  %{role: "user", content: "Task: #{task}"},
  # ... conversation history with observations
]
```

#### Context.Indexer (GenServer)

Background process that scans project files:
- Uses `Task.async_stream` for parallel file processing
- Leverages all CPU cores (`System.schedulers_online()`)
- Stores results in Context.Store

### 2. AST Layer

#### AST.Processor (Sourceror)

Pure Elixir AST analysis without NIFs:

**Parsing:**
```elixir
Sourceror.parse_string(source) # -> {:ok, ast}
```

**Analysis:**
```elixir
analyze(ast, source) # -> %{modules: [...], functions: [...], complexity: N}
```

**Patching (Write Back):**
```elixir
patch_function(source, :my_func, 2, new_body) # -> {:ok, modified_source}
```

**Context Slicing (For Small Models):**
```elixir
# Don't send 200 lines to a 3B model - send 20 relevant lines
slice_function(source, :chat, 2)           # Just the function
slice_function_with_deps(source, :chat, 2) # Function + called functions
slice_for_error(source, 42, "undefined")   # Context around error line
```

### 3. Provider Layer

#### Provider Behavior

```elixir
@callback chat(messages, opts) :: {:ok, response} | {:error, term}
@callback chat(messages, tools, opts) :: {:ok, response} | {:error, term}
@callback stream(messages, opts) :: {:ok, Enumerable.t()} | {:error, term}
```

#### Task Router

Classifies tasks and routes to appropriate provider:

| Task Type | Provider | Examples |
|-----------|----------|----------|
| Low-intensity | LM Studio (3B) | Format, docstring, explain, rename |
| High-intensity | Anthropic (Cloud) | Refactor, debug, architecture, implement |

```elixir
Router.classify("format this file")
# => %{intensity: :low, provider: Giulia.Provider.LMStudio, reason: "Simple task..."}

Router.classify("refactor the supervision tree")
# => %{intensity: :high, provider: Giulia.Provider.Anthropic, reason: "Task requires..."}
```

#### Providers

| Provider | Endpoint | Use Case |
|----------|----------|----------|
| Anthropic | api.anthropic.com | Heavy lifting, complex reasoning |
| LM Studio | localhost:1234 | Sub-second micro-tasks, cheap |
| Ollama | localhost:11434 | Medium tasks, local 32B models |

### 4. Agent Layer

#### Orchestrator (GenServer State Machine)

```elixir
defstruct [
  :task,
  :project_path,
  :messages,
  :status,

  # Counters for loop detection
  iteration: 0,
  consecutive_failures: 0,
  same_action_count: 0,

  # History for intervention
  last_action: nil,
  recent_errors: [],
  action_history: [],

  # Config
  max_iterations: 20,
  use_routing: true
]
```

**Loop of Death Prevention:**
```elixir
defp execute_loop(%{consecutive_failures: f}) when f >= 3 do
  force_intervention(state)  # Clear context, inject fresh AST summary
end
```

**Reflection (Skeptical Supervisor):**
```elixir
defp reflect_on_action(state, "read_file", %{path: path}) do
  if File.exists?(path) do
    :ok
  else
    similar = find_similar_paths(path)  # Jaro distance > 0.7
    {:intercept, "File not found. Did you mean: #{similar}?"}
  end
end
```

### 5. Tools Layer

#### Tools.Registry

Auto-discovers tools on boot:
```elixir
# In application.ex supervision tree
Giulia.Tools.Registry  # Starts and registers all tools

# Tools implement the behavior
@behaviour Giulia.Tools.Registry
def name, do: "read_file"
def description, do: "Read file contents"
def parameters, do: %{type: "object", properties: %{path: ...}}
```

Adding a new tool = adding a new .ex file. Plug-and-play.

#### StructuredOutput (JSON Guardrails)

Small models (3B) often mess up JSON. We handle it:

```elixir
# Extracts JSON from messy output
extract_json("Sure! Here's the JSON: {\"path\": \"foo.ex\"}")
# => {:ok, "{\"path\": \"foo.ex\"}"}

# Repairs unclosed braces
extract_json("{\"path\": \"foo.ex\"")
# => {:ok, "{\"path\": \"foo.ex\"}"}

# Strips markdown fences
extract_json("```json\n{\"path\": \"foo.ex\"}\n```")
# => {:ok, "{\"path\": \"foo.ex\"}"}
```

## Concurrency Model

### What Can Run in Parallel

1. **File Indexing** - All files scanned concurrently via `Task.async_stream`
2. **Multiple Agents** - Different tasks can run simultaneously
3. **Speculative Fixes** - Future: try 3 fixes in parallel, keep the one that passes tests

### What Must Be Sequential

1. **Think-Validate-Reflect-Execute** - Each step depends on previous
2. **Store Updates** - ETS writes are atomic but ordered per key
3. **Provider Calls** - Rate limited by API (cloud) or model (local)

## Error Handling

### Supervision Strategy

```
Supervisor (one_for_one)
├── Store crashes → Store restarts (ETS recreated, re-index needed)
├── Tools.Registry crashes → Registry restarts, re-discovers tools
├── Indexer crashes → Indexer restarts, re-scans project
├── Provider.Sup crashes → All provider connections restart
└── Agent.Sup crashes → All running tasks restart
```

### Tool Execution

Tools return `{:ok, result}` or `{:error, reason}`. Errors are:
1. Recorded in `recent_errors`
2. Formatted as CORRECTION message
3. Sent back to model for retry
4. After 3 failures → INTERVENTION

### Hallucination Recovery

```
Failure #1 → Send correction with error details
Failure #2 → Send correction with valid options
Failure #3 → INTERVENTION: Clear history, fresh AST summary, "Start over"
```

## Path Sandbox: The Jailbreak Prevention System

**The Senior Implementation**: We don't check for `..` strings (amateur hour). We expand to absolute paths and verify containment.

```elixir
defmodule Giulia.Core.PathSandbox do
  defstruct [:root, :root_parts, :allowed_external]

  @doc """
  Validate a path against the sandbox.
  The ONLY way file operations are allowed.
  """
  def validate(%__MODULE__{} = sandbox, path) do
    # Step 1: Expand the path (resolves .., symlinks, relative paths)
    expanded = path |> Path.join(sandbox.root) |> Path.expand()

    # Step 2: Split into components and compare
    expanded_parts = Path.split(expanded)
    root_parts = sandbox.root_parts

    # Path must start with EVERY component of root
    if starts_with_all?(expanded_parts, root_parts) do
      {:ok, expanded}
    else
      {:error, :sandbox_violation}
    end
  end
end
```

### What This Prevents

| Attack Vector | How Sandbox Blocks It |
|--------------|------------------------|
| `../../etc/passwd` | Expands to `/etc/passwd`, not under project root |
| `/home/user/.ssh/config` | Absolute path outside sandbox |
| Symlink to `/` | `Path.expand` follows symlinks, checks real path |
| Curious LLM exploring | All tool operations go through sandbox |

### Violation Response

When the model requests a file outside the sandbox:

```
SECURITY VIOLATION: Access denied to path outside project.

Attempted path: ~/.ssh/config
Project root: /home/user/projects/alpha

Giulia can only access files within the project where GIULIA.md lives.
```

The model gets this error, NOT the file contents. It learns the boundary.

## Future Architecture Extensions

### 1. Multi-Language Support (Sidecar Pattern)

```
┌─────────────────┐     ┌─────────────────┐
│     Giulia      │────▶│  Tree-sitter    │
│     (BEAM)      │◀────│  Sidecar (Rust) │
└─────────────────┘     └─────────────────┘
       Port/stdin-stdout
```

Why sidecar:
- NIF crash = BEAM crash (SEGFAULT)
- Sidecar crash = Supervisor restarts Port
- Isolation without losing capability

### 2. Speculative Parallel Fixes

```elixir
# When mix test fails, try 3 fixes in parallel
fixes = [fix_1, fix_2, fix_3]
|> Task.async_stream(&apply_and_test/1)
|> Enum.find(&test_passed?/1)
```

Local 3B model + fast tests = aggressive iteration. Claude Code can't do this efficiently due to latency/cost.

### 3. System-Wide Binary (Burrito)

Giulia compiles to a single executable via Burrito:

```bash
# Build for all platforms
MIX_ENV=prod mix release

# Output:
# burrito_out/giulia_windows.exe
# burrito_out/giulia_linux
# burrito_out/giulia_macos
# burrito_out/giulia_macos_arm
```

Install globally:
```bash
# Linux/macOS
sudo cp burrito_out/giulia_linux /usr/local/bin/giulia

# Windows
copy burrito_out\giulia_windows.exe C:\Tools\giulia.exe
# Add C:\Tools to PATH
```

Now type `giulia` from any directory. The binary:
1. Checks if daemon is running (via PID file in `~/.config/giulia`)
2. If not, starts daemon as background process
3. Connects and sends request

### 4. Docker Deployment

Giulia runs as a Dockerized daemon with a thin HTTP client on the host:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              HOST MACHINE                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐        ┌─────────────────────────────────────────┐ │
│  │   Thin Client   │        │         DOCKER CONTAINER                 │ │
│  │   (Elixir/Req)  │        │         giulia/core:latest               │ │
│  │                 │        │  ┌───────────────────────────────────┐   │ │
│  │  $ giulia "fix" │───────▶│  │      GIULIA DAEMON (BEAM)         │   │ │
│  │                 │  HTTP  │  │      Bandit on :4000              │   │ │
│  │  Sends JSON:    │  :4000 │  │                                   │   │ │
│  │  {path, message}│        │  │  ProjectContext(alpha)            │   │ │
│  │                 │        │  │  ProjectContext(beta)             │   │ │
│  │                 │        │  │                                   │   │ │
│  └─────────────────┘        │  └───────────────────────────────────┘   │ │
│                             │                                          │ │
│  ┌─────────────────┐        │  Volumes:                                │ │
│  │   LM Studio     │◀───────│  - giulia_data:/data (SQLite, cache)    │ │
│  │   localhost:1234│        │  - /projects (bind mount)               │ │
│  │                 │  via   │                                          │ │
│  │   Qwen 3B       │  host. │  Network:                                │ │
│  └─────────────────┘  docker│  - :4000 → HTTP API (only port needed)  │ │
│                       .internal → LM Studio                            │ │
│                             └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why HTTP Instead of Erlang Distribution?**

We tried Erlang distribution (`:rpc`, `Node.connect`). It failed across Docker boundaries
because Erlang distribution is bi-directional - the daemon needs to connect BACK to the
client, which doesn't work when Docker's 127.0.0.1 means something different than the host's.

HTTP is unidirectional. Client sends request, server responds. Port forwarding just works.
No EPMD (Erlang Port Mapper Daemon) drama. No bi-directional handshake nightmares.

**Build and Run:**
```bash
# Build the image
docker-compose build

# Start daemon
docker-compose up -d

# Use from any directory (Windows)
giulia "fix the bug"
giulia /init
giulia /status

# Use from any directory (Unix)
./giulia.sh "fix the bug"
```

**docker-compose.yml:**
```yaml
services:
  giulia:
    build: .
    container_name: giulia-daemon
    hostname: giulia-daemon
    ports:
      - "4000:4000"  # HTTP API - only port needed
    volumes:
      - giulia_data:/data
      - ${GIULIA_PROJECTS_PATH:-./}:/projects
    environment:
      - GIULIA_HOME=/data
      - GIULIA_PORT=4000
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  giulia_data:
```

**Path Mapping:**

The client sends the host path. The daemon maps it to the container path:

| Host Path | Container Path |
|-----------|----------------|
| `C:/Users/Dev/projects/alpha` | `/projects/alpha` |
| `/home/user/projects/beta` | `/projects/beta` |

Configure the projects mount via `GIULIA_PROJECTS_PATH` environment variable.

**Performance Optimization:**

The Indexer ignores heavy directories by default:
- `node_modules` (50k+ files)
- `_build`, `deps` (Elixir artifacts)
- `.git` (version control)
- `__pycache__`, `.venv` (Python)
- `target`, `dist`, `build` (compiled output)

This is critical on Windows/WSL2 where cross-filesystem I/O is expensive.

### 5. Distributed Mode (Future)

For multi-daemon setups (not client-daemon), Erlang distribution can connect daemons:

```
┌─────────────────┐     ┌─────────────────┐
│   Giulia@work   │◀───▶│   Giulia@home   │
│   (Anthropic)   │     │    (Ollama)     │
└─────────────────┘     └─────────────────┘
       Erlang Distribution (daemon-to-daemon)
```

Note: Client-to-daemon communication uses HTTP (see above). Erlang distribution is
reserved for daemon-to-daemon communication where both ends are BEAM nodes with
proper network visibility (not across Docker boundaries with NAT).

ETS can be replicated across nodes. Agent state can migrate.

## Performance Considerations

### Memory

- ETS tables are in-memory (fast but bounded by RAM)
- AST data is compact (metadata only, not full source)
- Context slicing keeps LLM prompts small

### CPU

- Indexer uses all cores for initial scan
- Provider calls are I/O bound (waiting on network/model)
- AST analysis is CPU bound but fast (Sourceror is optimized)

### Latency

| Provider | Typical Latency | Use Case |
|----------|-----------------|----------|
| LM Studio (3B) | <1 second | Micro-tasks |
| Ollama (32B) | 2-5 seconds | Medium tasks |
| Anthropic | 3-10 seconds | Complex reasoning |

Route simple tasks to fast providers. Save cloud for heavy lifting.

## Testing Strategy

### Unit Tests

- AST.Processor: Parse and analyze known code samples
- Tools: Validate changeset behavior
- StructuredOutput: JSON extraction edge cases
- Router: Task classification

### Integration Tests

- Provider: Mock HTTP responses
- Orchestrator: Full loop with mock provider
- Intervention: Verify loop detection triggers

### Property Tests (Future)

- AST round-trip: `source |> parse |> to_string == source`
- Tool validation: No invalid params pass changeset
- JSON extraction: Any valid JSON embedded in text is found
