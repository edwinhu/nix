{
  writeShellApplication,
  symlinkJoin,
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
# THREE NAMES, THREE SCRIPTS, one set of runtime inputs.
#
#   check-runts    a paragraph's last line holding a word or two, anywhere (a LINE
#                  break). The only one of the three that is real on slides.
#   check-widows   a paragraph's LAST line stranded at a page top (a PAGE break).
#   check-orphans  a paragraph's FIRST line stranded at a page bottom.
#
# `check-widows` now means widows. It meant runts for months, so the two page-break
# checkers REFUSE a slide deck -- exit 2 with a message naming check-runts -- rather
# than return the vacuous 0 a stale caller would read as clean.
#
# The script is referenced at its repo path rather than vendored into this repo:
# a copy here would be a second home for a file `vendor-parity.sh` does not track,
# which is the drift this suite already has elsewhere.

let
  # One derivation per name. A shared script dispatching on $0 would put the three
  # definitions back in one file, which is the arrangement this whole split undid.
  checker =
    name:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        (python3.withPackages (ps: [ ps.pymupdf ]))
        tinymist
      ];
      text = ''
        script="$HOME/projects/typst/scripts/${name}.py"
        if [ ! -f "$script" ]; then
          echo "${name}: $script not found (is ~/projects/typst checked out?)" >&2
          exit 2
        fi
        exec python3 "$script" "$@"
      '';
    };
in
symlinkJoin {
  name = "typst-line-checkers";
  paths = map checker [
    "check-runts"
    "check-widows"
    "check-orphans"
  ];
}
