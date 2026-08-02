{ pkgs }:

# tmc/nlm — Go CLI + MCP server for Google NotebookLM.
# https://github.com/tmc/nlm
#
# Built from pristine upstream main (replaces a stale `go install` of a
# personal fork). The single binary provides both the `nlm` CLI and the
# `nlm mcp` server subcommand, so installing the binary is all that's needed.
#
# Hash-bump loop: set hash/vendorHash to lib.fakeHash, run `nix run .#build`,
# and copy the "got:" value from the error (src hash first, then vendorHash).
pkgs.buildGoModule rec {
  pname = "nlm";
  version = "unstable-2026-06-14";

  src = pkgs.fetchFromGitHub {
    owner = "tmc";
    repo = "nlm";
    rev = "c19fbf7942098297615d1dd8d3ea3e34725c175a";
    hash = "sha256-dKt0U6HzZqrO0xWZaTNtmJbso52JwOL+Mr2gj5yxeQU=";
  };

  vendorHash = "sha256-G6CqGSKTwEvJB6CKNLMMgQfA4T5kDzMlQZcU/Xa+BlI=";

  # Trim the test/example surface; we only ship the CLI.
  subPackages = [ "cmd/nlm" ];

  meta = with pkgs.lib; {
    description = "CLI and MCP server for Google NotebookLM";
    homepage = "https://github.com/tmc/nlm";
    license = licenses.mit;
    mainProgram = "nlm";
    platforms = platforms.unix;
  };
}
