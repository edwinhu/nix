{
  lib,
  writers,
  python3,
  tinymist,
  makeWrapper,
  runCommand,
}:

# tinymist-lsp — `tinymist lsp` with a project root it cannot otherwise find.
#
# tinymist takes its root from LSP `initializationOptions.rootPath`. It has no
# `--root` flag (neither `tinymist --help` nor `tinymist lsp --help` offers
# one), it ignores TYPST_ROOT (a typst-CLI variable), and it is unaffected by
# cwd — `tinymist lint` returns the same error from the repo root as from a
# subdirectory. With no root it synthesises one package PER FILE
# ("@ws/p0:0.0.0") rooted at that file's own directory, so a shared
# `../../templates/theme.typ` import fails as "would escape the package root"
# and the file is never indexed: no diagnostics, no hover.
#
# Editors that expose LSP `initializationOptions` don't need this. Claude Code's
# `lspServers` config accepts only command/args/extensionToLanguage, so the only
# place left to inject rootPath is the wire. This sits in the stdio pipe,
# rewrites the single `initialize` request, then splices the streams raw.
#
# Why a Nix package rather than the script in the plugin repo: both the
# interpreter and tinymist itself resolve through PATH there, which in a Typst
# project routinely leads into `.pixi/envs/default/bin` — so the LSP's version
# and behaviour changed with the directory the editor was launched from. Here
# both are store paths.

let
  proxy = writers.writePython3Bin "tinymist-lsp-proxy" {
    libraries = [ ];
    # The message pump is intentionally a raw read/write/flush loop and the
    # framing arithmetic is byte-oriented; both read as "unusual" to a linter.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./tinymist-lsp/proxy.py);
in
runCommand "tinymist-lsp"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta = with lib; {
      description = "tinymist LSP with project-root injection for clients that cannot send initializationOptions";
      platforms = platforms.unix;
      mainProgram = "tinymist-lsp";
    };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${proxy}/bin/tinymist-lsp-proxy $out/bin/tinymist-lsp \
      --set TINYMIST_BIN ${lib.getExe tinymist}
  ''
