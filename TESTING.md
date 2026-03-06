# Testing Guide — Giulia

## Quick Reference

```bash
# Run ALL tests
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test"

# Run a single test file
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test test/giulia/inference/state_test.exs"

# Run a specific test by line number
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test test/giulia/prompt/builder_test.exs:124"

# Run with trace (verbose, shows each test name)
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test --trace"

# Run only previously failed tests
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test --failed"
```

## Why Tests Only Work in Docker

1. **EXLA** (ML backend for Nx) doesn't compile on Windows — no precompiled binaries for `x86_64-windows`
2. The Docker image has a working Linux EXLA build with CPU target
3. Tests **must** run from `/projects/Giulia` (the live-mounted volume), NOT from `/app` (baked-in image copy)

## Critical Rules

### Always use `/projects/Giulia`, never `/app`

The Dockerfile copies source into `/app` at build time. That's a **frozen snapshot**.
Your live edits on the host are mounted at `/projects/Giulia`.

```bash
# WRONG — runs stale code from image build time
docker compose exec giulia-daemon bash -c "MIX_ENV=test mix test"

# CORRECT — runs live code from host mount
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test"
```

### Always set `MIX_ENV=test`

Without it, the app tries to start Bandit on port 4000, which conflicts with the running daemon.
The `application.ex` skips the HTTP endpoint when `MIX_ENV=test`:

```elixir
# lib/giulia/application.ex, line ~116
children =
  if Mix.env() == :test do
    base_children  # no Bandit
  else
    base_children ++ [{Bandit, plug: Giulia.Daemon.Endpoint, port: port}]
  end
```

### The daemon must be running

Tests run inside the existing container via `docker compose exec`. Start it first:

```bash
docker compose up -d
```

## Test File Conventions

- Test files live under `test/giulia/` mirroring the `lib/giulia/` structure
- File naming: `lib/giulia/foo/bar.ex` → `test/giulia/foo/bar_test.exs`
- All tests use `use ExUnit.Case, async: true` unless they need shared state (GenServers, ETS)
- Use `Code.ensure_loaded!(Module)` before `function_exported?/3` checks — aliases don't trigger module loading

## Current Coverage (Build 114)

**48 test files**, **782 tests**, **0 failures**

### Modules WITH tests (48)

All files under `test/giulia/` — core logic, inference pipeline, knowledge graph, persistence, etc.

### Modules WITHOUT tests (81)

Grouped by priority for coverage:

#### High Priority — Core logic, pure functions, easy to test
- `ast/analysis.ex`, `ast/extraction.ex`, `ast/patcher.ex`, `ast/slicer.ex`
- `context/builder.ex`
- `knowledge/insights.ex`, `knowledge/metrics.ex`, `knowledge/topology.ex`
- `inference/context_builder/helpers.ex`, `inference/context_builder/messages.ex`
- `inference/engine/helpers.ex`, `inference/engine/step.ex`
- `inference/state/counters.ex`, `inference/state/tracking.ex`

#### Medium Priority — Stateful but testable with setup
- `core/project_context.ex`
- `intelligence/semantic_index.ex`, `intelligence/surgical_briefing.ex`
- `runtime/collector.ex`, `runtime/inspector.ex`
- `inference/tool_dispatch/executor.ex`, `inference/tool_dispatch/guards.ex`
- `tools/*.ex` (22 tool modules — each follows the same pattern)

#### Low Priority — Thin wrappers, routers, IO-heavy
- `daemon/routers/*.ex` (9 routers — integration tests needed, not unit)
- `client/*.ex` (7 modules — HTTP client, hard to unit test)
- `provider/*.ex` (5 modules — external API calls)
- `application.ex`, `daemon/endpoint.ex`, `daemon/skill_router.ex`
- `monitor/telemetry.ex`

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
