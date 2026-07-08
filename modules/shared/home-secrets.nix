{ config, pkgs, lib, user, nix-secrets, ... }:

let
  homeDir = if pkgs.stdenv.isDarwin then "/Users/${user}" else "/home/${user}";
in
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
    raindrop-token = {
      file = "${nix-secrets}/raindrop-token.age";
      mode = "400";
    };
    webhook-secret = {
      file = "${nix-secrets}/webhook-secret.age";
      mode = "400";
    };
    qualtrics-api-token = {
      file = "${nix-secrets}/qualtrics-api-token.age";
      mode = "400";
    };
    canvas-api-token = {
      file = "${nix-secrets}/canvas-api-token.age";
      mode = "400";
    };
    flakehub-token = {
      file = "${nix-secrets}/flakehub-token.age";
      mode = "400";
    };
    gws-client-secret-json = {
      file = "${nix-secrets}/gws-client-secret-json.age";
      mode = "400";
    };
    gws-credentials-enc = {
      file = "${nix-secrets}/gws-credentials-enc.age";
      mode = "400";
    };
    gws-encryption-key = {
      file = "${nix-secrets}/gws-encryption-key.age";
      mode = "400";
    };
  };
  
  # NOTE: nix-darwin home-manager activation runs without /dev/tty, so
  # age-plugin-yubikey cannot prompt for touch confirmation during build-switch.
  # SSH key remains the activation-time identity. YubiKey identities are kept
  # as recipients in nix-secrets/secrets.nix so manual decryption from a fresh
  # machine works (agenix CLI run interactively can use the plugin).
  age.identityPaths = [
    "${homeDir}/.ssh/id_ed25519_agenix"
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
    RAINDROP_TOKEN_FILE = "${tempDir}/raindrop-token";
    WEBHOOK_SECRET_FILE = "${tempDir}/webhook-secret";
    QUALTRICS_API_TOKEN_FILE = "${tempDir}/qualtrics-api-token";
    CANVAS_API_TOKEN_FILE = "${tempDir}/canvas-api-token";
    FLAKEHUB_TOKEN_FILE = "${tempDir}/flakehub-token";
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
  };

  # Create shell aliases for reading secrets when needed
  home.shellAliases = {
    get-google-search-api-key = "cat $GOOGLE_SEARCH_API_KEY_FILE";
    get-google-search-engine-id = "cat $GOOGLE_SEARCH_ENGINE_ID_FILE";
    get-gemini-api-key = "cat $GEMINI_API_KEY_FILE";
    get-claude-api-key = "cat $CLAUDE_API_KEY_FILE";
    get-readwise-token = "cat $READWISE_TOKEN_FILE";
    get-raindrop-token = "cat $RAINDROP_TOKEN_FILE";
    get-webhook-secret = "cat $WEBHOOK_SECRET_FILE";
    get-qualtrics-api-token = "cat $QUALTRICS_API_TOKEN_FILE";
    get-canvas-api-token = "cat $CANVAS_API_TOKEN_FILE";
    get-flakehub-token = "cat $FLAKEHUB_TOKEN_FILE";
  };

  home.activation.loginFlakeHub =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -n "''${DRY_RUN_CMD:-}" ]; then
        $DRY_RUN_CMD echo "Skipping FlakeHub login during dry run"
      else
        DETERMINATE_NIXD="$(PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH" command -v determinate-nixd || true)"
        if [ -n "$DETERMINATE_NIXD" ]; then
          TOKEN_TMP="$(mktemp)"
          trap 'rm -f "$TOKEN_TMP"' EXIT
          chmod 600 "$TOKEN_TMP"
          "${pkgs.age}/bin/age" --decrypt \
            -i "${homeDir}/.ssh/id_ed25519_agenix" \
            -o "$TOKEN_TMP" \
            "${nix-secrets}/flakehub-token.age"
          "$DETERMINATE_NIXD" login token --token-file "$TOKEN_TMP" >/dev/null
        fi
      fi
    '';

  # gws expects OAuth files at fixed paths. Keep the app-level client secret
  # and the portable user OAuth grant in agenix; token_cache.json is runtime
  # cache and can be regenerated from credentials.enc.
  home.activation.installGwsClientSecret =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      GWS_CONFIG_DIR="$HOME/.config/gws"
      $DRY_RUN_CMD mkdir -p "$GWS_CONFIG_DIR"
      $DRY_RUN_CMD chmod 700 "$GWS_CONFIG_DIR"

      install_gws_age_secret() {
        encrypted="$1"
        target="$2"
        identity="$3"

        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          $DRY_RUN_CMD install -m 600 "$encrypted" "$target"
          return
        fi

        tmp="$target.tmp.$$"
        rm -f "$tmp"
        umask 077
        "${pkgs.age}/bin/age" --decrypt -i "$identity" -o "$tmp" "$encrypted"
        install -m 600 "$tmp" "$target"
        rm -f "$tmp"
      }

      GWS_AGE_IDENTITY="${homeDir}/.ssh/id_ed25519_agenix"
      install_gws_age_secret "${nix-secrets}/gws-client-secret-json.age" "$GWS_CONFIG_DIR/client_secret.json" "$GWS_AGE_IDENTITY"
      install_gws_age_secret "${nix-secrets}/gws-credentials-enc.age" "$GWS_CONFIG_DIR/credentials.enc" "$GWS_AGE_IDENTITY"
      install_gws_age_secret "${nix-secrets}/gws-encryption-key.age" "$GWS_CONFIG_DIR/.encryption_key" "$GWS_AGE_IDENTITY"
    '';
}
