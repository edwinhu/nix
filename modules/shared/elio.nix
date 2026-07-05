{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "elio";
  version = "1.10.0";

  src = fetchFromGitHub {
    owner = "elio-fm";
    repo = "elio";
    rev = "v${version}";
    hash = "sha256-/Y9KtGoqD78QHmUtAooQmmI7ZTOSNY7DdrhHYVFMj5E=";
  };

  cargoHash = "sha256-7BP/LoNBnukD2ThtjhAYN8iv0cA0tNg3+GNAjlN6yIM=";

  # Sandbox-incompatible: trash, macOS Launch Services discovery, process groups
  doCheck = false;

  meta = {
    description = "Snappy, batteries-included terminal file manager with rich previews, inline images, bulk actions, and trash support";
    homepage = "https://github.com/elio-fm/elio";
    license = lib.licenses.mit;
    mainProgram = "elio";
  };
}
