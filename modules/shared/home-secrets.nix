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
    (if pkgs.stdenv.isDarwin then "/Users/${user}/.ssh/id_ed25519_agenix" else "/home/${user}/.ssh/id_ed25519_agenix")
  ];

  # Set environment variables pointing to agenix secret file paths
  # Applications can read from these paths at runtime
  # macOS: uses Darwin temp dir, Linux: uses XDG_RUNTIME_DIR (works on both NixOS and standalone)
  home.sessionVariables = let
    tempDir = if pkgs.stdenv.isDarwin then "$(getconf DARWIN_USER_TEMP_DIR)agenix" else "\${XDG_RUNTIME_DIR}/agenix";
  in {
    GOOGLE_SEARCH_API_KEY_FILE = "${tempDir}/google-search-api-key";
    GOOGLE_SEARCH_ENGINE_ID_FILE = "${tempDir}/google-search-engine-id";
    GEMINI_API_KEY_FILE = "${tempDir}/gemini-api-key";
    CLAUDE_API_KEY_FILE = "${tempDir}/claude-api-key";
    READWISE_TOKEN_FILE = "${tempDir}/readwise-token";
  };

  # Create shell aliases for reading secrets when needed
  home.shellAliases = {
    get-google-search-api-key = "cat $GOOGLE_SEARCH_API_KEY_FILE";
    get-google-search-engine-id = "cat $GOOGLE_SEARCH_ENGINE_ID_FILE";
    get-gemini-api-key = "cat $GEMINI_API_KEY_FILE";
    get-claude-api-key = "cat $CLAUDE_API_KEY_FILE";
    get-readwise-token = "cat $READWISE_TOKEN_FILE";
  };
}