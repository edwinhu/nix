{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "elio";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "elio-fm";
    repo = "elio";
    rev = "v${version}";
    hash = "sha256-9c96Im5Bbp/cULM0IBwQmha6iIxmb/3kWu/PvRZ2ssI=";
  };

  cargoHash = "sha256-tb9TnZD5bdPuULKEV0Q6oOIIP1ZIbw8roJFiIzCAvUg=";

  # Sandbox-incompatible: trash, macOS Launch Services discovery, process groups
  doCheck = false;

  meta = {
    description = "Snappy, batteries-included terminal file manager with rich previews, inline images, bulk actions, and trash support";
    homepage = "https://github.com/elio-fm/elio";
    license = lib.licenses.mit;
    mainProgram = "elio";
  };
}
