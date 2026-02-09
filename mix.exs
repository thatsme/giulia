defmodule Giulia.MixProject do
  use Mix.Project

  @version "0.1.0"
  # Build number - increment on each release
  @build 73

  def project do
    [
      app: :giulia,
      version: @version,
      build: @build,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases()
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
        cookie: "giulia_cluster_secret",
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

      # Binary compilation (client only)
      {:burrito, "~> 1.0", runtime: false}
    ]
  end
end
