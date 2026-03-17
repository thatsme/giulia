import Config

# =============================================================================
# Provider Configuration
# =============================================================================

# Default provider (used when not routing)
config :giulia,
  provider: Giulia.Provider.Anthropic

# Cloud provider (for high-intensity tasks)
config :giulia,
  cloud_provider: Giulia.Provider.Anthropic,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")

# Local provider (for low-intensity micro-tasks)
# Note: lm_studio_url is NOT set here - PathMapper.lm_studio_url() handles
# Docker vs native detection (uses host.docker.internal:12345 in container)
config :giulia,
  local_provider: Giulia.Provider.LMStudio,
  lm_studio_model: "qwen/qwen2.5-coder-14b",
  lm_studio_api_key: "lm-studio"  # Dummy key, LM Studio doesn't require it

# Ollama (alternative local provider for larger models)
config :giulia,
  ollama_base_url: "http://localhost:11434",
  ollama_model: "qwen2.5:32b"

# =============================================================================
# ArcadeDB (L2 persistent graph storage)
# =============================================================================

config :giulia,
  arcadedb_url: System.get_env("ARCADEDB_URL",
    if(System.get_env("GIULIA_IN_CONTAINER") == "true",
      do: "http://arcadedb:2480",
      else: "http://localhost:2480")),
  arcadedb_db: System.get_env("ARCADEDB_DB", "giulia"),
  arcadedb_user: System.get_env("ARCADEDB_USER", "root"),
  arcadedb_password: System.get_env("ARCADEDB_PASSWORD", "playwithdata")

# =============================================================================
# Logging
# =============================================================================

config :logger,
  level: :info

# =============================================================================
# Nx / EXLA Configuration (Semantic Search)
# =============================================================================

config :nx, :default_backend, EXLA.Backend
