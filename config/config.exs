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
# Logging
# =============================================================================

config :logger,
  level: :info
