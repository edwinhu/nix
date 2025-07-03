{ config, pkgs, user, nix-secrets, ... }:

{
  sops.defaultSopsFile = "${nix-secrets}/secrets.yaml";
  sops.age.keyFile = 
    if pkgs.stdenv.isDarwin then
      "/Users/${user}/.ssh/id_ed25519_agenix"
    else
      "/home/${user}/.ssh/id_ed25519_agenix";
  sops.age.sshKeyPaths = [ ];
  sops.secrets.GOOGLE_SEARCH_API_KEY = { };
  sops.secrets.GOOGLE_SEARCH_ENGINE_ID = { };
  sops.secrets.GEMINI_API_KEY = { };
  sops.secrets.CLAUDE_API_KEY = { };
}