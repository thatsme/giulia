import Config

# =============================================================================
# Runtime Configuration (loaded at runtime, not compile time)
# =============================================================================

# LM Studio model (from environment)
if lm_studio_model = System.get_env("LM_STUDIO_MODEL") do
  config :giulia, lm_studio_model: lm_studio_model
end

# Anthropic API key
if anthropic_key = System.get_env("ANTHROPIC_API_KEY") do
  config :giulia, anthropic_api_key: anthropic_key
end

# Logging level (default: info, set GIULIA_LOG_LEVEL=debug for verbose)
log_level =
  case System.get_env("GIULIA_LOG_LEVEL") do
    "debug" -> :debug
    "warning" -> :warning
    "error" -> :error
    _ -> :info
  end

config :logger, level: log_level
