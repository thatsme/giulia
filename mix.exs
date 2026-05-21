# Version stamp source of truth.
# Keep the following docs in sync when bumping @version or the build counter:
#   - README.md (header block)
#   - ARCHITECTURE.md (Document version line)
#   - API.md (Document version line + /health example response)
# See docs/orders/2026-05-21-doc-reconciliation-report.md.
defmodule Giulia.MixProject do
  use Mix.Project

  @version "0.3.8"
  # Build number - increment on each release
  @build 161

  def project do
    [
      app: :giulia,
      version: @version,
      build: @build,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: [
        check: :test,
        "check.strict": :test,
        "check.fast": :test,
        credo: :test,
        dialyzer: :dev,
        sobelow: :dev
      ],
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tools],
      mod: {Giulia.Application, []}
    ]
  end

  defp escript do
    [
      main_module: Giulia.Client,
      name: "giulia"
    ]
  end

  defp releases do
    [
      # The Daemon Release (for Docker)
      # This is the long-running BEAM node that clients connect to
      giulia: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        cookie: String.to_atom(System.get_env("GIULIA_COOKIE", "giulia_dev")),
        steps: [:assemble],
        rel_templates_path: "rel"
      ],

      # The Thin Client Release (for Burrito binary)
      # This is compiled to a native binary and distributed to users
      giulia_client: [
        include_executables_for: [:unix, :windows],
        applications: [runtime_tools: :temporary],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            windows: [os: :windows, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64],
            macos: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},

      # HTTP server (daemon API)
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},

      # TUI rendering
      {:owl, "~> 0.11"},

      # JSON parsing
      {:jason, "~> 1.4"},

      # Schema validation
      {:ecto, "~> 3.11"},

      # AST parsing (pure Elixir)
      {:sourceror, "~> 1.7"},

      # SQLite for conversation history
      {:exqlite, "~> 0.20"},

      # Knowledge graph (pure Elixir, no NIFs)
      {:libgraph, "~> 0.16"},

      # Semantic search (Hierarchical Concept Search)
      {:nx, "~> 0.10"},
      {:exla, "~> 0.10"},
      {:bumblebee, "~> 0.6"},
      {:axon, "~> 0.6"},

      # Persistent key-value store (pure Elixir, crash-safe)
      {:cubdb, "~> 2.0"},

      # Binary compilation (client only)
      {:burrito, "~> 1.0", runtime: false},

      # MCP (Model Context Protocol) server
      {:anubis_mcp, "~> 1.0"},

      # Property-based testing (test-only)
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false},

      # --- Quality tooling (dev/test only) ---
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      # Standard check — what every commit should pass
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ],
      # Strict — release gate; adds Dialyzer and Sobelow
      "check.strict": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow --config",
        "dialyzer",
        "test --cover"
      ],
      # Fast feedback for the inner dev loop
      "check.fast": [
        "compile --warnings-as-errors",
        "credo --strict",
        "test --stale"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/giulia.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [
        :unmatched_returns,
        :error_handling,
        :missing_return,
        :extra_return,
        :no_improper_lists
      ],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "ARCHITECTURE.md",
        "API.md",
        "CONTRIBUTING.md",
        "SECURITY.md"
      ],
      source_url: "https://github.com/thatsme/giulia",
      source_ref: "v#{@version}"
    ]
  end
end
