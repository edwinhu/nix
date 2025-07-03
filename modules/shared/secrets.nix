{ config, pkgs, user, nix-secrets, ... }:

{
  sops.defaultSopsFile = "${nix-secrets}/secrets.yaml";
  sops.age.keyFile = "/home/${user}/.config/sops/age/keys.txt";
  sops.age.sshKeyPaths = [ ];
  sops.secrets.GOOGLE_SEARCH_API_KEY = { 
    mode = "0400";
  };
  sops.secrets.GOOGLE_SEARCH_ENGINE_ID = { 
    mode = "0400";
  };
  sops.secrets.GEMINI_API_KEY = { 
    mode = "0400";
  };
  sops.secrets.CLAUDE_API_KEY = { 
    mode = "0400";
  };
}