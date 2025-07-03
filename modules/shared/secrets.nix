{
  sops.defaultSopsFile = ./../../secrets.yaml;
  sops.age.keyFile = "/Users/vwh7mb/.config/sops/age/keys.txt";
  sops.secrets.GOOGLE_SEARCH_API_KEY = { };
  sops.secrets.GOOGLE_SEARCH_ENGINE_ID = { };
  sops.secrets.GEMINI_API_KEY = { };
  sops.secrets.CLAUDE_API_KEY = { };
}