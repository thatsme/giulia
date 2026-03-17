# Testing Guide — Giulia

## Quick Reference

### Recommended: Isolated test environment (`docker-compose.test.yml`)

Uses a dedicated compose file with its own ArcadeDB instance, fresh volumes,
and `MIX_ENV=test` baked in. No interference with the running dev daemon.

```bash
# Run ALL tests (starts ArcadeDB, runs tests, exits)
docker compose -f docker-compose.test.yml run --rm giulia-test

# Run a single test file
docker compose -f docker-compose.test.yml run --rm giulia-test test/giulia/inference/state_test.exs

# Run a specific test by line number
docker compose -f docker-compose.test.yml run --rm giulia-test test/giulia/prompt/builder_test.exs:124

# Run with trace (verbose)
docker compose -f docker-compose.test.yml run --rm -e TEST_ARGS="--trace" giulia-test

# Run only previously failed tests
docker compose -f docker-compose.test.yml run --rm -e TEST_ARGS="--failed" giulia-test

# Clean up test containers and volumes when done
docker compose -f docker-compose.test.yml down -v
```

### Alternative: exec into dev container (quick but less isolated)

Runs tests inside the running dev daemon. Faster (no startup), but CubDB state
and ETS tables from the running daemon can cause flaky failures.

**The daemon must be running** for this approach. Start it first with `docker compose up -d`.

Replace `/projects/Giulia` below with the container-side path where your source
is mounted (this matches the host path you configured in `docker-compose.yml`
under `GIULIA_PROJECTS_PATH`).

```bash
# Run ALL tests
docker compose exec giulia-worker bash -c "cd /projects/YourProject && MIX_ENV=test mix test"

# Run a single test file
docker compose exec giulia-worker bash -c "cd /projects/YourProject && MIX_ENV=test mix test test/giulia/inference/state_test.exs"

# Run a specific test by line number
docker compose exec giulia-worker bash -c "cd /projects/YourProject && MIX_ENV=test mix test test/giulia/prompt/builder_test.exs:124"
```

## NEVER run `mix format` on the full project inside Docker

If your host uses CRLF line endings (Windows), running `mix format` inside the
Linux container converts every `.ex` and `.exs` file to LF, causing 100+ files
to appear modified in `git diff` and spurious test failures.

**If you need to format:** run `mix format` on the host, or format only the specific
files you changed — never `mix format` on the full project from inside the container.

## Verifying changes don't break tests

Always follow this workflow when making code changes:

1. **Baseline first**: `git stash`, run full test suite, record exact failure count + which modules
2. **Restore and test**: `git stash pop`, run full test suite again
3. **Compare module-by-module**: same modules + same failure count = zero regressions
4. **Never assume**: don't claim failures are "pre-existing" without the before/after proof

```bash
# Using the isolated test environment (recommended):

# Step 1: Baseline
git stash
docker compose -f docker-compose.test.yml run --rm giulia-test 2>&1 | tail -5

# Step 2: After changes
git stash pop
docker compose -f docker-compose.test.yml run --rm giulia-test 2>&1 | tail -5

# Step 3: Compare (should show same failure modules, same counts)
```

## Why Tests Only Work in Docker

1. **EXLA** (ML backend for Nx) doesn't compile on Windows — no precompiled binaries for `x86_64-windows`
2. The Docker image has a working Linux EXLA build with CPU target
3. Tests **must** run from the live-mounted volume, NOT from `/app` (baked-in image copy)

## Critical Rules

### Always use the mounted source path, never `/app`

The Dockerfile copies source into `/app` at build time. That's a **frozen snapshot**.
Your live edits are mounted under `/projects/` (the path depends on your
`GIULIA_PROJECTS_PATH` setting in `docker-compose.yml`). For the exec approach,
always `cd` to the mounted path before running tests.

```bash
# WRONG — runs stale code from image build time
docker compose exec giulia-worker bash -c "MIX_ENV=test mix test"

# CORRECT — runs live code from host mount
docker compose exec giulia-worker bash -c "cd /projects/YourProject && MIX_ENV=test mix test"
```

The isolated test environment (`docker-compose.test.yml`) handles this automatically
via the `test-entrypoint.sh` script.

### Always set `MIX_ENV=test` (exec approach only)

Without it, the app tries to start Bandit on port 4000, which conflicts with the running daemon.
The `application.ex` skips the HTTP endpoint when `MIX_ENV=test`:

```elixir
children =
  if Mix.env() == :test do
    base_children  # no Bandit
  else
    base_children ++ [{Bandit, plug: Giulia.Daemon.Endpoint, port: port}]
  end
```

The isolated test environment sets `MIX_ENV=test` automatically.

## Test File Conventions

- Test files live under `test/giulia/` mirroring the `lib/giulia/` structure
- File naming: `lib/giulia/foo/bar.ex` → `test/giulia/foo/bar_test.exs`
- Adversarial tests: `test/giulia/foo/bar_adversarial_test.exs`
- Integration tests: `test/integration/` (full HTTP stack via Plug.Test)
- All tests use `use ExUnit.Case, async: true` unless they need shared state (GenServers, ETS)
- Use `Code.ensure_loaded!(Module)` before `function_exported?/3` checks — aliases don't trigger module loading

## Current Coverage (Build 138)

**84+ test files**, **1707 tests**

### Known Failures

**Build 138: 1,707 tests, 0 failures** (isolated test environment).

All previously known failures (ArcadeDB setup, CubDB corruption, ETS state pollution,
private function tests) were fixed in Build 138. If you see failures, they are real
regressions — investigate before merging.

### Test Categories

| Category | Files | Tests | Description |
|----------|-------|-------|-------------|
| Unit tests | 68 | ~1111 | Direct module testing |
| Adversarial tests | 15 | ~371 | Malformed input, edge cases, security |
| Integration tests | 1 | 52 | Full HTTP stack via Plug.Test |

### Modules WITH Tests (68 unique modules covered)

#### Core
- `core/context_manager.ex` — `context_manager_test.exs`
- `core/path_mapper.ex` — `path_mapper_test.exs`
- `core/path_sandbox.ex` — `path_sandbox_test.exs` + `path_sandbox_adversarial_test.exs`

#### AST
- `ast/analysis.ex` — `analysis_test.exs`
- `ast/extraction.ex` — `extraction_test.exs`
- `ast/patcher.ex` — `patcher_test.exs`
- `ast/processor.ex` — `processor_test.exs` + `pathological_test.exs`
- `ast/slicer.ex` — `slicer_test.exs`

#### Context
- `context/builder.ex` — `builder_test.exs`
- `context/indexer.ex` — `indexer_test.exs` + `indexer_race_test.exs`
- `context/store.ex` — `store_test.exs` + `store_concurrency_test.exs`
- `context/store/formatter.ex` — `store/formatter_test.exs`
- `context/store/query.ex` — `store/query_test.exs`

#### Inference
- `inference/approval.ex` — `approval_test.exs`
- `inference/bulk_replace.ex` — `bulk_replace_test.exs`
- `inference/context_builder.ex` — `context_builder_test.exs`
- `inference/context_builder/helpers.ex` — `context_builder/helpers_test.exs`
- `inference/context_builder/intervention.ex` — `context_builder/intervention_test.exs`
- `inference/context_builder/messages.ex` — `context_builder/messages_test.exs`
- `inference/context_builder/preview.ex` — `context_builder/preview_test.exs`
- `inference/engine.ex` — `engine_test.exs`
- `inference/engine/helpers.ex` — `engine/helpers_test.exs`
- `inference/engine/step.ex` — `engine/step_test.exs`
- `inference/escalation.ex` — `escalation_test.exs`
- `inference/events.ex` — `events_test.exs`
- `inference/orchestrator.ex` — `orchestrator_test.exs`
- `inference/pool.ex` — `pool_test.exs`
- `inference/rename_mfa.ex` — `rename_mfa_test.exs`
- `inference/response_parser.ex` — `response_parser_test.exs`
- `inference/state.ex` — `state_test.exs`
- `inference/state/counters.ex` — `state/counters_test.exs`
- `inference/state/tracking.ex` — `state/tracking_test.exs`
- `inference/tool_dispatch.ex` — `tool_dispatch_test.exs`
- `inference/tool_dispatch/guards.ex` — `tool_dispatch/guards_test.exs`
- `inference/trace.ex` — `trace_test.exs`
- `inference/transaction.ex` — `transaction_test.exs`
- `inference/verification.ex` — `verification_test.exs`

#### Intelligence
- `intelligence/architect_brief.ex` — `architect_brief_test.exs`
- `intelligence/plan_validator.ex` — `plan_validator_test.exs`
- `intelligence/preflight.ex` — `preflight_test.exs`

#### Knowledge
- `knowledge/analyzer.ex` — `analyzer_test.exs`
- `knowledge/builder.ex` — `builder_test.exs` + `builder_adversarial_test.exs`
- `knowledge/insights.ex` — `insights_test.exs`
- `knowledge/macro_map.ex` — `macro_map_test.exs`
- `knowledge/metrics.ex` — `metrics_test.exs`
- `knowledge/store.ex` — `store_test.exs` + `partial_graph_test.exs`
- `knowledge/topology.ex` — `topology_test.exs`

#### Monitor
- `monitor/store.ex` — `store_test.exs` + `store_adversarial_test.exs`
- `monitor/telemetry.ex` — `telemetry_adversarial_test.exs`

#### Persistence
- `persistence/loader.ex` — `loader_test.exs` + `loader_adversarial_test.exs`
- `persistence/merkle.ex` — `merkle_test.exs` + `merkle_adversarial_test.exs`
- `persistence/store.ex` — `store_test.exs` + `store_adversarial_test.exs`
- `persistence/writer.ex` — `writer_test.exs` + `writer_adversarial_test.exs`

#### Providers (via adversarial test)
- `provider/anthropic.ex` — `response_adversarial_test.exs`
- `provider/gemini.ex` — `response_adversarial_test.exs`
- `provider/groq.ex` — `response_adversarial_test.exs`
- `provider/lm_studio.ex` — `response_adversarial_test.exs`
- `provider/router.ex` — `router_test.exs`
- `provider.ex` — `provider_test.exs`

#### Tools
- `tools/commit_changes.ex` — `commit_changes_test.exs`
- `tools/get_staged_files.ex` — `get_staged_files_test.exs`
- `tools/read_file.ex` — `read_file_test.exs`
- `tools/registry.ex` — `registry_test.exs`
- `tools/respond.ex` — `respond_test.exs`
- `tools/think.ex` — `think_test.exs`
- All 22 tool modules — `tools_contract_test.exs` (name, description, parameters)

#### Other
- `structured_output.ex` — `structured_output_test.exs` + `structured_output_adversarial_test.exs`
- `structured_output/parser.ex` — `parser_test.exs` + `parser_adversarial_test.exs`
- `prompt/builder.ex` — `builder_test.exs`
- `utils/diff.ex` — `diff_test.exs`
- `version.ex` — `version_test.exs`
- `daemon/helpers.ex` — `helpers_test.exs`

### Modules Covered by Integration Tests Only (10)

These modules have no dedicated unit test file but are exercised end-to-end
by `test/integration/api_adversarial_test.exs` (52 tests via Plug.Test):

- `daemon/endpoint.ex` — all core routes (health, command, ping, status, projects)
- `daemon/routers/index.ex` — 6 routes tested
- `daemon/routers/knowledge.ex` — 11 routes tested
- `daemon/routers/monitor.ex` — 3 routes tested
- `daemon/routers/discovery.ex` — 3 routes tested
- `daemon/skill_router.ex` — exercised via all sub-routers
- `inference/engine/response.ex` — via POST /api/command
- `inference/tool_dispatch/executor.ex` — via tool execution pipeline
- `inference/tool_dispatch/staging.ex` — via /api/transaction
- `inference/tool_dispatch/approval.ex` — via /api/approval

### Modules WITHOUT Tests (40)

Grouped by reason:

#### Not Testable Without External Dependencies (13)
These require live LLM connections, external services, or multi-node setups:
- `client.ex` — HTTP client entry point (needs running daemon)
- `client/approval.ex` — approval UI (needs daemon + LLM)
- `client/commands.ex` — CLI command dispatch (needs daemon)
- `client/daemon.ex` — daemon lifecycle management
- `client/http.ex` — HTTP request helpers (needs daemon)
- `client/output.ex` — terminal output formatting
- `client/renderer.ex` — Owl TUI rendering (visual)
- `client/repl.ex` — interactive REPL loop
- `provider/ollama.ex` — Ollama API (needs running Ollama)
- `intelligence/embedding_serving.ex` — EXLA model loading (tested indirectly)
- `intelligence/semantic_index.ex` — embedding search (needs EmbeddingServing)
- `runtime/collector.ex` — BEAM runtime data (needs live processes)
- `runtime/inspector.ex` — BEAM introspection (needs live processes)

#### Thin Dispatch / Orchestration Layers (8)
These are mostly glue code — the modules they call ARE tested:
- `application.ex` — OTP supervision tree (startup only)
- `inference/engine/commit.ex` — commit dispatch (calls tested modules)
- `inference/engine/startup.ex` — engine init (calls tested modules)
- `inference/supervisor.ex` — supervisor spec (OTP boilerplate)
- `inference/tool_dispatch/special.ex` — bulk ops dispatch
- `intelligence/surgical_briefing.ex` — briefing composition
- `knowledge/behaviours.ex` — behaviour analysis
- `knowledge/store/reader.ex` — store read delegation

#### Sub-Routers (4)
Partially covered by integration tests, remaining routes untested:
- `daemon/routers/approval.ex` — 2 routes
- `daemon/routers/intelligence.ex` — 4 routes
- `daemon/routers/runtime.ex` — 8 routes
- `daemon/routers/search.ex` — 3 routes
- `daemon/routers/transaction.ex` — 3 routes

#### Tool Modules Without Dedicated Tests (15)
All have contract tests (name/description/parameters) via `tools_contract_test.exs`.
Missing execution tests for:
- `tools/bulk_replace.ex`
- `tools/cycle_check.ex`
- `tools/edit_file.ex`
- `tools/get_context.ex`
- `tools/get_function.ex`
- `tools/get_impact_map.ex`
- `tools/get_module_info.ex`
- `tools/list_files.ex`
- `tools/lookup_function.ex`
- `tools/patch_function.ex`
- `tools/rename_mfa.ex`
- `tools/run_mix.ex`
- `tools/run_tests.ex`
- `tools/search_code.ex`
- `tools/search_meaning.ex`
- `tools/trace_path.ex`
- `tools/write_file.ex`
- `tools/write_function.ex`

## Integration Test Procedure

Integration tests at `test/integration/api_adversarial_test.exs` use `Plug.Test`
to simulate HTTP requests without a TCP connection. They exercise the full stack:

```
HTTP Request → Plug.Router → GenServer → ETS → Business Logic → JSON Response
```

### How it works

```elixir
use Plug.Test
alias Giulia.Daemon.Endpoint

@opts Endpoint.init([])
@project_path "/projects/Giulia"  # matches the volume mount in docker-compose.yml

# Simulate GET with query params
defp get(path, query_params \\ %{}) do
  query = URI.encode_query(query_params)
  full_path = if query == "", do: path, else: "#{path}?#{query}"
  :get |> conn(full_path) |> Endpoint.call(@opts)
end

# Simulate POST with JSON body
defp post(path, body) do
  :post
  |> conn(path, Jason.encode!(body))
  |> put_req_header("content-type", "application/json")
  |> Endpoint.call(@opts)
end
```

### What it covers

The 6 dispatcher modules that can't be unit-tested without mocking their
downstream dependencies. Instead, we test the real pipeline end-to-end:

| Module | Tested Via | What's Validated |
|--------|-----------|-----------------|
| Engine.Response | POST /api/command | Unknown command → error JSON |
| ToolDispatch.Executor | POST /api/command | Tool pipeline doesn't crash |
| ToolDispatch.Staging | POST /api/transaction | Transaction lifecycle |
| ToolDispatch.Approval | POST /api/approval | Approval flow |
| Engine.Commit | POST /api/command | Staged file commit |
| ToolDispatch.Special | POST /api/command | Bulk operation dispatch |

### Key insight

In a test environment, the knowledge graph may be empty (no project scanned).
Tests for module-specific queries (centrality, dependents, etc.) accept both
200 (graph populated) and 404 (module not found) — they validate the HTTP
layer, not the business logic.

## Writing New Tests

### Template for pure function modules

```elixir
defmodule Giulia.Foo.BarTest do
  use ExUnit.Case, async: true

  alias Giulia.Foo.Bar

  describe "function_name/arity" do
    test "handles normal input" do
      assert Bar.function_name(input) == expected
    end

    test "handles edge case" do
      assert Bar.function_name(nil) == {:error, :invalid}
    end
  end
end
```

### Template for GenServer modules

```elixir
defmodule Giulia.Foo.ServerTest do
  use ExUnit.Case, async: false  # shared state

  setup do
    # Start isolated instance if possible
    {:ok, pid} = Giulia.Foo.Server.start_link(name: nil)
    %{pid: pid}
  end

  test "does something", %{pid: pid} do
    assert GenServer.call(pid, :something) == :ok
  end
end
```

### Template for Tool modules

```elixir
defmodule Giulia.Tools.MyToolTest do
  use ExUnit.Case, async: true

  alias Giulia.Tools.MyTool

  test "name/0 returns tool name" do
    assert MyTool.name() == "my_tool"
  end

  test "description/0 is non-empty" do
    assert is_binary(MyTool.description())
    assert String.length(MyTool.description()) > 0
  end

  test "parameters/0 returns valid schema" do
    params = MyTool.parameters()
    assert is_map(params)
    assert Map.has_key?(params, "type")
  end
end
```

### Template for adversarial tests

```elixir
defmodule Giulia.Foo.BarAdversarialTest do
  @moduledoc """
  Adversarial tests for Foo.Bar.

  Targets: nil inputs, huge inputs, malformed data, type confusion,
  concurrent access, boundary values.
  """
  use ExUnit.Case, async: true  # or false if shared state

  alias Giulia.Foo.Bar

  describe "function_name with malformed input" do
    test "nil input" do
      # Should not crash
      result = Bar.function_name(nil)
      assert result == {:error, _} or result == :default
    end

    test "extremely large input" do
      big = String.duplicate("x", 100_000)
      result = Bar.function_name(big)
      assert is_binary(result) or match?({:error, _}, result)
    end
  end
end
```
