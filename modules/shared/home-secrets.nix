{ config, pkgs, user, ... }:

{
  # Set environment variables to read from agenix-decrypted secret files
  home.sessionVariables = {
    GOOGLE_SEARCH_API_KEY = "$(cat ${config.age.secrets.google-search-api-key.path})";
    GOOGLE_SEARCH_ENGINE_ID = "$(cat ${config.age.secrets.google-search-engine-id.path})";
    GEMINI_API_KEY = "$(cat ${config.age.secrets.gemini-api-key.path})";
    CLAUDE_API_KEY = "$(cat ${config.age.secrets.claude-api-key.path})";
  };
}