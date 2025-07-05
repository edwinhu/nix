{ config, pkgs, agenix, user, nix-secrets, ... }:

{
  age.secrets = {
    google-search-api-key = {
      file = "${nix-secrets}/google-search-api-key.age";
      owner = user;
      mode = "400";
    };
    google-search-engine-id = {
      file = "${nix-secrets}/google-search-engine-id.age";
      owner = user;
      mode = "400";
    };
    gemini-api-key = {
      file = "${nix-secrets}/gemini-api-key.age";
      owner = user;
      mode = "400";
    };
    claude-api-key = {
      file = "${nix-secrets}/claude-api-key.age";
      owner = user;
      mode = "400";
    };
    readwise-token = {
      file = "${nix-secrets}/readwise-token.age";
      owner = user;
      mode = "400";
    };
  };
  
  age.identityPaths = [
    (if pkgs.stdenv.isDarwin then "/Users/${user}/.ssh/id_ed25519" else "/home/${user}/.ssh/id_ed25519")
  ];
}