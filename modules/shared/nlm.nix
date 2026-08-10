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
  version = "unstable-2026-07-31";

  src = pkgs.fetchFromGitHub {
    owner = "tmc";
    repo = "nlm";
    rev = "23a4c4540f8fa6897397b9f688003bb774328914";
    hash = "sha256-2Ij7VUrCnzg8L7tl0MHa2h3hTj/Bo8ta0TUzwOj7+V4=";
  };

  vendorHash = "sha256-Td8WYx2LnF6F69aZm7LwVGA+Q77bBeUJ4qx3H3gwK7Q=";

  # Trim the test/example surface; we only ship the CLI.
  subPackages = [ "cmd/nlm" ];

  # The chat render-cache test mkdirs under $HOME, which is the unwritable
  # /homeless-shelter in the sandbox.
  preCheck = ''
    export HOME=$(mktemp -d)
  '';

  meta = with pkgs.lib; {
    description = "CLI and MCP server for Google NotebookLM";
    homepage = "https://github.com/tmc/nlm";
    license = licenses.mit;
    mainProgram = "nlm";
    platforms = platforms.unix;
  };
}
