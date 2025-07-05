{ config, pkgs, user, nix-secrets, ... }:

{
  age.secrets = {
    google-search-api-key = {
      file = "${nix-secrets}/google-search-api-key.age";
      mode = "400";
    };
    google-search-engine-id = {
      file = "${nix-secrets}/google-search-engine-id.age";
      mode = "400";
    };
    gemini-api-key = {
      file = "${nix-secrets}/gemini-api-key.age";
      mode = "400";
    };
    claude-api-key = {
      file = "${nix-secrets}/claude-api-key.age";
      mode = "400";
    };
    readwise-token = {
      file = "${nix-secrets}/readwise-token.age";
      mode = "400";
    };
  };
  
  age.identityPaths = [
    (if pkgs.stdenv.isDarwin then "/Users/${user}/.ssh/id_ed25519" else "/home/${user}/.ssh/id_ed25519")
  ];

  # Set environment variables to read from agenix-decrypted secret files
  home.sessionVariables = {
    GOOGLE_SEARCH_API_KEY = "$(cat ${config.age.secrets.google-search-api-key.path})";
    GOOGLE_SEARCH_ENGINE_ID = "$(cat ${config.age.secrets.google-search-engine-id.path})";
    GEMINI_API_KEY = "$(cat ${config.age.secrets.gemini-api-key.path})";
    CLAUDE_API_KEY = "$(cat ${config.age.secrets.claude-api-key.path})";
    READWISE_TOKEN = "$(cat ${config.age.secrets.readwise-token.path})";
  };
}