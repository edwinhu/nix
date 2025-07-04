{ config, pkgs, user, ... }:

{
  # Set environment variables to read from agenix-decrypted secret files
  home.sessionVariables = {
    GOOGLE_SEARCH_API_KEY = "$(cat /run/agenix/google-search-api-key)";
    GOOGLE_SEARCH_ENGINE_ID = "$(cat /run/agenix/google-search-engine-id)";
    GEMINI_API_KEY = "$(cat /run/agenix/gemini-api-key)";
    CLAUDE_API_KEY = "$(cat /run/agenix/claude-api-key)";
  };
}