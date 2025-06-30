{
  sops.defaultSopsFile = ./../../secrets.yaml;
  sops.gnupg.home = "/Users/vwh7mb/.gnupg";
  sops.gnupg.sshKeyPaths = [];
  sops.secrets.GOOGLE_SEARCH_API_KEY = { };
  sops.secrets.GOOGLE_SEARCH_ENGINE_ID = { };
  sops.secrets.GEMINI_API_KEY = { };
  sops.secrets.CLAUDE_API_KEY = { };
}