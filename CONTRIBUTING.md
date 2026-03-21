# Contributing to Giulia

Thank you for your interest in contributing to Giulia. This document explains
how to contribute and what to expect from the process.

---

## Before You Start

Giulia is a local-first AI development agent built on Elixir/OTP. Contributions
are welcome, but please understand the project's philosophy before proposing changes:

- **OTP first** — state lives in GenServers and ETS, not in chat history
- **Daemon-client** — persistent background service, not a CLI that restarts
- **Native AST** — Sourceror (pure Elixir) for code analysis, not tree-sitter NIFs
- **Provider agnostic** — supports Anthropic, Ollama, LM Studio, Gemini, Groq
- **Observable** — telemetry events across the OODA pipeline, SSE dashboard
- **Sandboxed** — Giulia can only access files under the project root

If your contribution aligns with these principles, it's likely a good fit.

---

## Contributor License Agreement (CLA)

**All contributors must agree to the CLA before their code can be merged.**

By submitting a pull request, you automatically agree to the CLA for minor
contributions (documentation, typos, small fixes).

For significant contributions (new tools, architectural changes, new providers),
you must explicitly sign the CLA by including this statement in your PR:

> I have read the Giulia CLA and agree to its terms.
> My GitHub username is [username] and my legal name is [full name].

Read the full CLA in [CLA.md](CLA.md).

**Why the CLA includes a relicensing clause:** The CLA allows the project to be
relicensed in the future without requiring permission from every contributor. This
is standard practice for projects that may evolve commercially, and does not affect
your right to use your own contributions however you wish.

---

## What We Welcome

- **New tools** — code analysis, refactoring aids, project health checks
- **New LLM providers** — additional provider integrations for the router
- **Bug fixes** — especially around CubDB persistence, Property Graph edge cases
- **Documentation** — architecture explanations, API usage examples
- **Observability** — new telemetry events, monitor dashboard improvements
- **Docker improvements** — build performance, multi-platform support
- **Test coverage** — especially for tool modules and integration tests

## What We Don't Want

- External service dependencies that break the local-first model
- Tree-sitter NIFs or C dependencies (Sourceror handles Elixir AST natively)
- Authentication/authorization layers (Giulia is a local development tool)
- Complexity for its own sake

---

## How to Contribute

1. **Fork** the repository
2. **Create a branch** — `git checkout -b feature/my-tool` or `fix/cubdb-recovery`
3. **Write your code** — follow the existing patterns in `lib/giulia/`
4. **Add tests** — see [TESTING.md](TESTING.md) for the test infrastructure
5. **Run tests** — `docker compose -f docker-compose.test.yml run --rm giulia-test`
6. **Open a pull request** — describe what you built and why

### Tool Contributions

New tools must implement the tool behaviour:

```elixir
defmodule Giulia.Tools.MyTool do
  @moduledoc "One-line description of what this tool does."

  @doc "Tool name as used in LLM tool calls."
  def name, do: "my_tool"

  @doc "Human-readable description for the tool registry."
  def description, do: "Short description for tool discovery"

  @doc "JSON Schema for tool parameters."
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string", "description" => "What the tool needs"}
      },
      "required" => ["input"]
    }
  end

  @doc "Execute the tool. Returns {:ok, result} or {:error, reason}."
  def execute(params, opts) do
    project_path = Keyword.fetch!(opts, :project_path)
    # Tool logic here
    {:ok, "result"}
  end
end
```

Tools are auto-discovered by `Giulia.Tools.Registry` on boot.

### Router/Endpoint Contributions

New API endpoints must include a `@skill` annotation:

```elixir
@skill %{
  intent: "What this endpoint does in plain English",
  endpoint: "GET /api/category/my_endpoint",
  params: %{path: :required, module: :optional},
  returns: "JSON description of the response shape",
  category: "category_name"
}
get "/my_endpoint" do
  # ...
end
```

This makes the endpoint self-describing via the discovery API.

---

## Code Style

Follow [CODING_CONVENTIONS.md](CODING_CONVENTIONS.md) for idiomatic Elixir patterns.

Key points:
- Pattern match in function heads, not if/else chains
- Return tagged tuples `{:ok, _} | {:error, _}` — never raise for expected failures
- Never create atoms from runtime strings (`String.to_existing_atom` or tuple keys)
- Use `Integer.parse` not `String.to_integer`
- Keep GenServer callbacks thin — delegate to pure functions
- Every public function gets `@spec`, every module gets `@moduledoc`
- Run `mix format` on the host before committing (never inside Docker — see TESTING.md)

---

## Build Counter

Every code modification MUST increment `@build` in `mix.exs` before building.
This is how we track which version is running on client vs server.

---

## Testing

Tests run inside Docker. See [TESTING.md](TESTING.md) for full details.

```bash
# Full suite (isolated environment, recommended)
docker compose -f docker-compose.test.yml run --rm giulia-test

# Single file
docker compose -f docker-compose.test.yml run --rm giulia-test test/giulia/foo_test.exs
```

The full test suite must pass with zero regressions from your changes.

---

## Questions

Open an issue or start a discussion on GitHub. The project owner (Alessio Battistutta)
reviews contributions personally.

---

*Giulia — The BEAM-native AI development agent.*
*Copyright 2026 Alessio Battistutta — Apache License 2.0*
