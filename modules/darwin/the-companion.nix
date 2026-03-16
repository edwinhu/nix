# the-companion - Web UI for Claude Code agents
# Runs as launchd service, exposed on tailnet via tailscale serve
{ pkgs, lib, user, ... }:

let
  tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  port = 3456;

  # Wrapper script that reads agenix _FILE secrets into env vars before exec'ing
  companion-wrapper = pkgs.writeShellScript "the-companion-wrapper" ''
    # Read agenix secret files into environment variables
    for var in READWISE_TOKEN_FILE GEMINI_API_KEY_FILE GOOGLE_SEARCH_ENGINE_ID_FILE GOOGLE_SEARCH_API_KEY_FILE; do
      file="''${!var}"
      if [ -n "$file" ] && [ -f "$file" ]; then
        value="$(cat "$file")"
        case "$var" in
          READWISE_TOKEN_FILE)    export READWISE_TOKEN="$value" ;;
          GEMINI_API_KEY_FILE)    export GOOGLE_API_KEY="$value" ;;
          GOOGLE_SEARCH_ENGINE_ID_FILE) export GOOGLE_SEARCH_ENGINE_ID="$value" ;;
          GOOGLE_SEARCH_API_KEY_FILE)   export GOOGLE_SEARCH_API_KEY="$value" ;;
        esac
      fi
    done

    exec "/Users/${user}/.local/bin/the-companion" serve --port ${toString port}
  '';
in
{
  launchd.user.agents.the-companion = {
    serviceConfig = {
      ProgramArguments = [
        "${companion-wrapper}"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Background";
      AbandonProcessGroup = true;
      StandardOutPath = "/tmp/the-companion.log";
      StandardErrorPath = "/tmp/the-companion.log";
      EnvironmentVariables = {
        PATH = "/Users/${user}/.local/bin:/Users/${user}/.nix-profile/bin:${pkgs.bun}/bin:${pkgs.nodejs}/bin:/usr/bin:/bin";
        HOME = "/Users/${user}";
        NODE_ENV = "production";
      };
    };
  };

  launchd.user.agents.the-companion-tailserve = {
    serviceConfig = {
      ProgramArguments = [
        tailscale
        "serve"
        "--bg"
        (toString port)
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion-tailserve.log";
      StandardErrorPath = "/tmp/the-companion-tailserve.log";
    };
  };
}
