# CLAUDE.md - Project Context for AI Assistants

## What is Giulia?

Giulia is a high-performance, local-first AI development agent built in Elixir. She is designed to eventually replace Claude Code by leveraging the BEAM's strengths: fault-tolerance, concurrency, and stateful long-running processes.

**Key Differentiator**: Giulia runs as a **persistent background daemon** with **multi-project awareness**. You don't restart the agent every time you change folders.

## Core Philosophy

1. **OTP First** - State lives in GenServers and ETS, not in chat history
2. **Daemon-Client** - System-wide binary talks to persistent background daemon
3. **No Shell Confusion** - All file operations use native Elixir `File` module or `Path` structs
4. **Native AST** - Use Sourceror (pure Elixir) for code analysis, not tree-sitter NIFs
5. **Provider Agnostic** - Anthropic API at work, Ollama (local Qwen 32B) at home
6. **Structured Intelligence** - All tool calls use Ecto schemas for validation
7. **Sandboxed** - Giulia can ONLY access files under GIULIA.md (the constitution)

## Project Structure

```
lib/
├── giulia.ex                    # Main API (legacy direct interface)
├── giulia/
│   ├── application.ex           # OTP Supervision Tree
│   ├── client.ex                # HTTP thin client (escript entry point)
│   ├── cli.ex                   # Legacy RPC client (deprecated)
│   ├── daemon.ex                # Persistent background service
│   ├── provider.ex              # LLM Provider behavior
│   ├── structured_output.ex     # JSON validation + extraction for small models
│   │
│   ├── core/
│   │   ├── context_manager.ex   # Routes PWD to correct ProjectContext
│   │   ├── project_context.ex   # Per-project GenServer (AST, history, constitution)
│   │   ├── path_sandbox.ex      # Security: prevents reading outside project
│   │   └── path_mapper.ex       # Host/container path translation
│   │
│   ├── daemon/
│   │   └── endpoint.ex          # Bandit HTTP API (Plug.Router on :4000)
│   │
│   ├── inference/
│   │   ├── orchestrator.ex      # OODA loop (THINK-VALIDATE-REFLECT-EXECUTE)
│   │   ├── pool.ex              # Provider connection pooling
│   │   └── supervisor.ex        # Inference supervisor hierarchy
│   │
│   ├── provider/
│   │   ├── anthropic.ex         # Claude API (cloud, high-intensity)
│   │   ├── ollama.ex            # Ollama API (local, heavy)
│   │   ├── lm_studio.ex         # LM Studio (local, fast micro-tasks)
│   │   └── router.ex            # Task classification (low vs high intensity)
│   │
│   ├── context/
│   │   ├── store.ex             # ETS-backed project state
│   │   ├── indexer.ex           # Background AST scanner (Task.async_stream)
│   │   └── builder.ex           # Dynamic system prompt construction
│   │
│   ├── prompt/
│   │   └── builder.ex           # Constitution + context building for LLM
│   │
│   ├── ast/
│   │   └── processor.ex         # Sourceror: parse, analyze, patch, slice
│   │
│   ├── agent/
│   │   ├── orchestrator.ex      # Legacy orchestrator (see inference/)
│   │   └── router.ex            # Task routing (local vs cloud)
│   │
│   └── tools/
│       ├── registry.ex          # Auto-discovers tools on boot
│       ├── read_file.ex         # Sandboxed file reading
│       ├── write_file.ex        # Sandboxed file writing
│       ├── edit_file.ex         # Edit file with AST patching
│       ├── run_mix.ex           # Run mix commands
│       ├── search_code.ex       # Code search
│       ├── list_files.ex        # List directory contents
│       ├── get_context.ex       # Get surrounding code context
│       ├── get_function.ex      # Extract function by name/arity
│       ├── get_module_info.ex   # Get module metadata
│       ├── think.ex             # Model thinking/reasoning
│       └── respond.ex           # Final response to user
```

## Key Design Decisions

### Why Daemon-Client Architecture?

```
Terminal A: ~/alpha    Terminal B: ~/beta
    │                        │
    ▼                        ▼
┌─────────────────────────────────────────┐
│         GIULIA DAEMON (BEAM)            │
│  ProjectContext(alpha)  ProjectContext(beta)
│  - AST cached           - AST cached
│  - History in SQLite    - History in SQLite
│  - Constitution loaded  - Constitution loaded
└─────────────────────────────────────────┘
```

- **Warm LLM**: Local models take time to load. Keep them warm.
- **Hot AST Cache**: Don't re-index 500 files every terminal session.
- **Multi-Project**: Isolated contexts, instant switching.
- **System-Wide**: Type `giulia` anywhere.

### Why GIULIA.md (The Constitution)?

Claude Code guesses your project's intent. Giulia **reads her constitution**.

```markdown
## Taboos (Never Do This)
- Never use umbrella projects
- Never add dependencies without approval

## Preferred Patterns
- Use context modules for business logic
```

If the model violates the constitution, **Giulia intercepts and rewrites** before showing you.

### Why Path Sandbox?

Giulia can ONLY read/write files **under the folder where GIULIA.md lives**. Not `~/.ssh/config`. Not `/etc/passwd`. The model can't escape.

```elixir
# The Senior Way (not checking for ".." strings)
PathSandbox.validate(sandbox, path)
# Expands to absolute path, verifies containment
```

### Why Sourceror instead of Tree-sitter?
- Pure Elixir, no C compiler needed
- Can parse AND write back code with formatting preserved
- Better for "father-killing" (Giulia improving her own code)
- Tree-sitter can be added later as a sidecar for multi-language support

### Why Two Providers (Cloud + Local)?
- **Cloud (Anthropic)**: Heavy lifting - architecture, debugging, multi-file refactoring
- **Local (LM Studio/Qwen 3B)**: Micro-tasks - docstrings, formatting, variable names
- Router classifies tasks and picks the right brain
- Don't use a sledgehammer (Claude) to hang a picture frame

## Development Commands

```bash
# Compile
mix compile

# Run interactive
iex -S mix

# Test
mix test
```

## Building the Light Client (HTTP-based thin client)

```bash
# Build escript (development, requires Elixir runtime)
mix escript.build
# Output: ./giulia (Unix) or giulia (Windows batch)

# Build native binary via Burrito (production, standalone)
MIX_ENV=prod mix release giulia_client

# Output locations (Burrito):
# burrito_out/giulia_windows.exe
# burrito_out/giulia_linux
# burrito_out/giulia_macos
# burrito_out/giulia_macos_arm
```

## Building the Docker Daemon

```bash
# Build Docker image
docker-compose build
# Or: docker build -t giulia/core:latest .

# Start daemon (background)
docker-compose up -d

# Check logs
docker-compose logs -f

# Stop daemon
docker-compose down

# Full rebuild (no cache)
docker-compose build --no-cache
```

## Running Without Docker (development)

```bash
# Start daemon in foreground
iex -S mix

# In another terminal, use the client
mix escript.build && ./giulia "hello"
```

## Storage Locations

- **Global**: `~/.config/giulia/` - Daemon logs, PID file, global cache
- **Per-Project**: `.giulia/` - Chat history (SQLite), local cache
- **Constitution**: `GIULIA.md` - Project rules, tech stack, taboos

## Configuration Rules (CRITICAL)

**NO HARDCODED URLS OR PATHS IN CODE**

All external URLs (LM Studio, Anthropic, etc.) MUST be resolved through:
1. `System.get_env("ENV_VAR_NAME")` - First priority
2. `Giulia.Core.PathMapper` functions - Docker-aware defaults
3. `Application.get_env(:giulia, :key)` - Application config

**Example - WRONG:**
```elixir
# DON'T DO THIS
url = "http://127.0.0.1:1234/v1/models"
```

**Example - CORRECT:**
```elixir
# DO THIS - uses env var or Docker-aware default
url = Giulia.Core.PathMapper.lm_studio_models_url()
```

**PathMapper Functions:**
- `lm_studio_url/0` - Chat completions endpoint
- `lm_studio_models_url/0` - Models list endpoint
- `lm_studio_base_url/0` - Base URL without path
- `in_container?/0` - Detect if running in Docker

## Environment Variables

- `ANTHROPIC_API_KEY` - Required for Anthropic provider
- `LM_STUDIO_URL` - LM Studio endpoint (e.g., `http://192.168.33.1:1234/v1/chat/completions`)
- `GIULIA_IN_CONTAINER` - Set to "true" when running in Docker
- `GIULIA_PROJECTS_PATH` - Host path to mount as /projects in Docker
- `GIULIA_PATH_MAPPING` - Path mapping for host/container translation (e.g., `C:/Dev=/projects`)
- `GIULIA_HOME` - Data directory inside container (default: /data)
- `GIULIA_PORT` - HTTP API port (default: 4000)

## Debugging

```bash
# Check if LM Studio is responding
curl http://localhost:1234/v1/models

# Watch daemon logs (Docker)
docker-compose logs -f

# Run with verbose logging (development)
iex -S mix
# In iex: Logger.configure(level: :debug)
```

**Common issues:**
- `:max_iterations_exceeded` - Model keeps looping without calling `respond`. Try simpler task or check LM Studio model.
- `:no_provider_available` - Neither LM Studio nor Anthropic API available. Check LM Studio is running.
- Search returns nothing - Dependencies (`deps/`) are not searched, only project source files.

## Current Status

- HTTP daemon-client architecture implemented (Bandit on :4000)
- Multi-project awareness via ContextManager
- Path sandbox security in place
- OODA inference loop (THINK-VALIDATE-REFLECT-EXECUTE) implemented
- 12+ tools registered (read, write, edit, search, etc.)
- AST indexing with Sourceror (parallel scanning)
- LM Studio provider working, Anthropic/Ollama need verification
- Docker deployment ready (Dockerfile + docker-compose.yml)
- HTTP thin client (`client.ex`) is the active entry point

## Next Steps

1. Verify Anthropic and Ollama providers work end-to-end
2. Implement Owl TUI for live streaming responses
3. Add constitution enforcement in reflection step
4. Expand test coverage (currently minimal)
5. Father-killing: Use Giulia to build Giulia's remaining features
6. Clean up legacy `cli.ex` (RPC-based) once HTTP client is proven
