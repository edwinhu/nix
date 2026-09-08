{
  writeShellApplication,
  python3,
  tinymist,
}:

# check-widows — the Typst widow/orphan linter, with an interpreter that has pymupdf.
#
# pymupdf is the only non-stdlib import in the whole typst checker suite, and
# nothing declared it: ~/projects/typst has no pixi.toml, pyproject.toml or
# requirements.txt, and the script's `#!/usr/bin/env python3` resolves to the
# system interpreter, which does not carry it. The script then exits 2 — and a
# caller that reads only the finding count records that crash as "0 violations,
# clean". A slide deck was audited as widow-free on 2026-08-28 while carrying 28.
#
# Same argument as tinymist-lsp.nix: leaving the interpreter to PATH inside a
# Typst project routinely lands in `.pixi/envs/default/bin`, so the result
# depended on the directory you launched from. Here it is a store path.
#
# tinymist is a runtime input because the script compiles a .typ argument itself
# before reading the PDF back.
#
# The script is referenced at its repo path rather than vendored into this repo:
# a copy here would be a second home for a file `vendor-parity.sh` does not track,
# which is the drift this suite already has elsewhere.

writeShellApplication {
  name = "check-widows";
  runtimeInputs = [
    (python3.withPackages (ps: [ ps.pymupdf ]))
    tinymist
  ];
  text = ''
    script="$HOME/projects/typst/scripts/check-widows.py"
    if [ ! -f "$script" ]; then
      echo "check-widows: $script not found (is ~/projects/typst checked out?)" >&2
      exit 2
    fi
    exec python3 "$script" "$@"
  '';
}
