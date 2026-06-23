{ pkgs }:

# leaf — terminal Markdown previewer with a GUI-like experience.
# https://github.com/RivoLink/leaf
#
# Renders code blocks, tables, LaTeX and Mermaid diagrams; watch mode
# (re-render on save), fuzzy/directory file pickers, vim keybindings, and
# stdin/inline preview. Not in nixpkgs, so built from the upstream tag.
#
# Rust; every dependency resolves from crates.io, so we vendor the upstream
# Cargo.lock (./Cargo.lock) and skip the cargoHash bump entirely.
#
# Version bump: change `version` (the tag has no `v` prefix), refresh
# ./Cargo.lock from that tag, and update `hash` (set to lib.fakeHash, run
# `nix run .#build`, copy the "got:" value from the error).
#
# Note: leaf's `--update` self-updater can't work from the read-only nix store;
# bump the version here instead. All other modes (watch/picker/inline) work.
pkgs.rustPlatform.buildRustPackage rec {
  pname = "leaf";
  version = "1.24.2";

  src = pkgs.fetchFromGitHub {
    owner = "RivoLink";
    repo = "leaf";
    rev = version;
    hash = "sha256-mKB3x7HaO48uMzxaKpep+69D52RgIKTtvVNdm/EOJaU=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta = with pkgs.lib; {
    description = "Terminal Markdown previewer with a GUI-like experience";
    homepage = "https://github.com/RivoLink/leaf";
    license = licenses.mit;
    mainProgram = "leaf";
    platforms = platforms.unix;
  };
}
